#!/usr/bin/env python3
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import unittest

import runner
import worker

SHA = '1'*40


def status():
    command = 'git sparse-checkout set --no-cone -- "/*" "!/*/" /ghostty-next /cmux-tui/ /scripts/\n'
    command += 'git -c core.hooksPath=/dev/null checkout -q --detach '+SHA
    return dict(id='study-test', state='failed', workspace='study-workspace',
                inputs={'src.000': 'sha256:'+'2'*64}, command='exec /bin/bash -c '+shlex.quote(command))


class Logic(unittest.TestCase):
    def test_timeout_kills_sleeping_descendant_in_outer_group(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            fixture = '''import json, os, pathlib, subprocess, sys, time
child = subprocess.Popen([sys.executable, '-c', 'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)'])
stat = pathlib.Path('/proc') / str(child.pid) / 'stat'
pathlib.Path(sys.argv[1]).write_text(json.dumps({'child': child.pid, 'start': stat.read_text().rsplit(')',1)[1].split()[19], 'pgid': os.getpgrp()}))
print('timeout diagnostic marker', flush=True)
time.sleep(60)
'''
            timings = []
            pid_file = out/'owned.json'
            output = io.StringIO()
            try:
                with redirect_stdout(output), self.assertRaises(worker.RunFailure) as error:
                    worker.run_step('sleep-tree', [sys.executable, '-c', fixture, str(pid_file)],
                                    out, dict(os.environ), timings, out, timeout=1.5)
                self.assertEqual(error.exception.code, 124)
                owned = json.loads(pid_file.read_text())
                self.assertEqual(owned['pgid'], os.getpgrp())
                stat = Path('/proc')/str(owned['child'])/'stat'
                if stat.exists():
                    self.assertIn(stat.read_text().rsplit(')', 1)[1].split()[0], ('Z', 'X'))
                receipt = json.loads((out/'timings.json').read_text())[0]
                self.assertEqual(receipt['exit_code'], 124)
                self.assertEqual(receipt['process_exit_code'], -signal.SIGKILL)
                self.assertTrue(receipt['timeout'])
                self.assertIsNone(receipt['cleanup_error'])
                self.assertEqual(receipt['timeout_seconds'], 1.5)
                self.assertEqual(receipt['cwd'], str(out))
                self.assertFalse(receipt['cpu_complete'])
                printed_receipt, diagnostic = map(json.loads, output.getvalue().splitlines())
                self.assertEqual(printed_receipt, receipt)
                self.assertEqual(diagnostic['tail'], 'timeout diagnostic marker\n')
                self.assertFalse(diagnostic['truncated'])
            finally:
                # A failing regression must not leave its own sleeping fixture behind.
                if pid_file.exists():
                    owned = json.loads(pid_file.read_text())
                    try:
                        descriptor = os.pidfd_open(owned['child'])
                    except ProcessLookupError:
                        pass
                    else:
                        try:
                            stat = Path('/proc')/str(owned['child'])/'stat'
                            if stat.exists() and stat.read_text().rsplit(')', 1)[1].split()[19] == owned['start']:
                                try:
                                    signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                                except ProcessLookupError:
                                    pass
                        finally:
                            os.close(descriptor)

    def test_failure_prints_bounded_log_tail_before_raising(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            output = io.StringIO()
            fixture = "import sys; print('x'*100000); print('offline cache miss'); sys.exit(7)"
            with redirect_stdout(output), self.assertRaises(worker.RunFailure) as error:
                worker.run_step('failure', [sys.executable, '-c', fixture],
                                out, dict(os.environ), [], out)
            self.assertEqual(error.exception.code, 7)
            receipt, diagnostic = map(json.loads, output.getvalue().splitlines())
            self.assertEqual(receipt['exit_code'], 7)
            self.assertEqual(diagnostic['event'], 'failed_step_log')
            self.assertEqual(diagnostic['log_bytes'], (out/'failure.log').stat().st_size)
            self.assertEqual(diagnostic['tail_bytes'], worker.FAILURE_TAIL_BYTES)
            self.assertTrue(diagnostic['truncated'])
            self.assertTrue(diagnostic['tail'].endswith('offline cache miss\n'))
            self.assertLess(len(output.getvalue()), worker.FAILURE_TAIL_BYTES + 2048)

    def test_cancellation_prints_failure_log(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            output = io.StringIO()
            fixture = "import os, signal, time; print('cancel marker', flush=True); os.kill(os.getppid(), signal.SIGTERM); time.sleep(60)"
            with redirect_stdout(output), self.assertRaises(worker.RunFailure) as error:
                worker.run_step('cancel', [sys.executable, '-c', fixture],
                                out, dict(os.environ), [], out)
            self.assertEqual(error.exception.code, 128 + signal.SIGTERM)
            receipt, diagnostic = map(json.loads, output.getvalue().splitlines())
            self.assertEqual(receipt['cancelled_signal'], signal.SIGTERM)
            self.assertIsNone(receipt['cleanup_error'])
            self.assertEqual(diagnostic['tail'], 'cancel marker\n')

    def test_only_consumer_cargo_is_offline(self):
        tools = Path('/tmp/private-tools')
        producer = worker.cargo_command(tools, 'producer')
        consumer = worker.cargo_command(tools, 'consumer')
        self.assertNotIn('--offline', producer)
        self.assertEqual(consumer, producer + ['--offline'])
        self.assertEqual(producer[0:3], [str(tools/'cargo'), 'build', '--locked'])

    def test_source_metadata(self):
        config = runner.source_config(status(), SHA, '/tmp/cmux-cache-portability-test')
        self.assertEqual(config['patterns'], ['/*', '!/*/', '/ghostty-next', '/cmux-tui/', '/scripts/'])
        self.assertEqual(config['source_inputs'], status()['inputs'])

    def test_reject_active_study(self):
        value = status(); value['state'] = 'running'
        with self.assertRaises(ValueError):
            runner.source_config(value, SHA, '/tmp/cmux-cache-portability-test')

    def test_reject_wrong_sha(self):
        with self.assertRaises(ValueError):
            runner.source_config(status(), '3'*40, '/tmp/cmux-cache-portability-test')

    def test_reject_pack_gap_and_base(self):
        for inputs in ({'src.001': 'sha256:'+'2'*64}, {'base.000': 'sha256:'+'2'*64}):
            value = status(); value['inputs'] = inputs
            with self.assertRaises(ValueError):
                runner.source_config(value, SHA, '/tmp/cmux-cache-portability-test')

    def test_no_network_in_generation_and_shell_syntax(self):
        config = runner.source_config(status(), SHA, '/tmp/cmux-cache-portability-test')
        config['mode'] = 'producer'
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)/'plan'
            runner.write_plan(config, out)
            self.assertFalse((out/'submit-receipt.json').exists())
            for name in ('producer.sh', 'commands.sh'):
                subprocess.run(['bash', '-n', str(out/name)], check=True)
            command = (out/'commands.sh').read_text()
            self.assertIn('src.000=sha256:', command)
            self.assertNotIn('artifact-put', command)

    def test_parts_hashes_and_reassembly(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            archive = path/'archive'
            archive.write_bytes(bytes(range(256))*3)
            parts = worker.split_archive(archive, path, limit=100)
            self.assertTrue(all(p['bytes'] <= 100 for p in parts))
            self.assertEqual(b''.join((path/p['name']).read_bytes() for p in parts), archive.read_bytes())
            self.assertTrue(all(worker.digest(path/p['name']) == p['sha256'] for p in parts))

    def test_consumer_generation_checks_producer_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            config = runner.source_config(status(), SHA, '/tmp/cmux-cache-portability-test')
            config['mode'] = 'producer'
            config_path = base/'producer.json'; config_path.write_text(json.dumps(config))
            receipts = base/'receipts'; receipts.mkdir()
            (receipts/'exit.json').write_text(json.dumps(dict(exit_code=0, mode='producer', source_sha=SHA)))
            archive = receipts/'archive'; archive.write_bytes(b'synthetic archive')
            parts = worker.split_archive(archive, receipts)
            (receipts/'cache-manifest.json').write_text(json.dumps(dict(identity=dict(sha=SHA, root=config['root']),
                  parts=parts, archive_bytes=archive.stat().st_size)))
            argv = ['python3', str(Path(runner.__file__)), 'consumer', '--producer-config', str(config_path),
                    '--producer-directory', str(receipts), '--output', str(base/'consumer')]
            subprocess.run(argv, check=True, stdout=subprocess.DEVNULL)
            for file in ('consumer.sh', 'commands.sh'):
                subprocess.run(['bash', '-n', str(base/'consumer'/file)], check=True)
            (receipts/'cache.000').write_bytes(b'tampered')
            argv[-1] = str(base/'bad-consumer')
            bad = subprocess.run(argv, capture_output=True)
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn(b'invalid archive part', bad.stderr)

    def test_fresh_requires_first_invocation_evidence(self):
        self.assertTrue(worker.fresh('       Fresh ghostty-vt-sys v0.1.0\n'))
        self.assertFalse(worker.fresh('Compiling ghostty-vt-sys v0.1.0'))
        self.assertFalse(worker.fresh('Fresh ghostty-vt-sys v0.1.0\nRunning `/target/ghostty-vt-sys-a/build-script-build`'))

    def test_actual_strip_retains_native_and_dependency_hashes(self):
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)/'target'
            (target/'debug/.fingerprint').mkdir(parents=True)
            native = target/'debug/build/ghostty-vt-sys-abc/out/libghostty-vt.a'
            native.parent.mkdir(parents=True)
            native.write_bytes(b'synthetic native output')
            own = target/'debug/deps/libghostty_vt-abc.rlib'
            own.parent.mkdir(parents=True)
            own.write_bytes(b'workspace output')
            dependency = target/'debug/deps/libcmux_transport_rewrite-abc.rlib'
            dependency.write_bytes(b'build dependency library')
            fingerprint = target/'debug/.fingerprint/cmux-transport-rewrite-abc/lib-cmux_transport_rewrite.json'
            fingerprint.parent.mkdir()
            fingerprint.write_bytes(b'build dependency fingerprint')
            # A workspace test named http must not delete the third-party http library.
            third_party = target/'debug/deps/libhttp-abc.rlib'
            third_party.write_bytes(b'third-party library')
            test_binary = target/'debug/deps/http-abc'
            test_binary.write_bytes(b'workspace test binary')
            metadata = Path(directory)/'metadata.json'
            metadata.write_text(json.dumps({'packages': [
                {'name': 'ghostty-vt', 'targets': [
                    {'name': 'ghostty_vt', 'kind': ['lib']}, {'name': 'http', 'kind': ['test']}]},
                {'name': 'ghostty-vt-sys', 'targets': [{'name': 'ghostty_vt_sys', 'kind': ['lib']}]},
                {'name': 'cmux-transport-rewrite', 'targets': [{'name': 'cmux_transport_rewrite', 'kind': ['lib']}]}
            ]}))
            before = worker.native_hashes(target)
            dependencies_before = worker.retained_dependency_hashes(target)
            subprocess.run(worker.prune_command(repo, target, metadata), check=True)
            self.assertFalse(own.exists())
            self.assertFalse(test_binary.exists())
            self.assertEqual(third_party.read_bytes(), b'third-party library')
            self.assertEqual(worker.native_hashes(target), before)
            self.assertEqual(worker.retained_dependency_hashes(target), dependencies_before)
            dependency.write_bytes(b'changed dependency')
            self.assertNotEqual(worker.retained_dependency_hashes(target), dependencies_before)
            native.write_bytes(b'changed')
            self.assertNotEqual(worker.native_hashes(target), before)

    def test_retained_dependency_requires_fingerprint_and_library(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            dependency = target/'debug/deps/libcmux_transport_rewrite-abc.rlib'
            dependency.parent.mkdir(parents=True)
            dependency.write_bytes(b'library')
            with self.assertRaisesRegex(RuntimeError, 'no complete cmux-transport-rewrite'):
                worker.retained_dependency_hashes(target)
            fingerprint = target/'debug/.fingerprint/cmux-transport-rewrite-abc/lib-cmux_transport_rewrite.json'
            fingerprint.parent.mkdir(parents=True)
            fingerprint.write_bytes(b'fingerprint')
            self.assertEqual(len(worker.retained_dependency_hashes(target)), 2)
            dependency.unlink()
            with self.assertRaisesRegex(RuntimeError, 'no complete cmux-transport-rewrite'):
                worker.retained_dependency_hashes(target)

    def test_real_mtime_manifest(self):
        repo = Path(__file__).resolve().parents[2]
        helper = str(repo/'scripts/blacksmith-testbox-source-mtimes.py')
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)/'src'
            target = source/'target'
            target.mkdir(parents=True)
            unchanged = source/'same.rs'; unchanged.write_text('same')
            changed = source/'changed.rs'; changed.write_text('old')
            old = 1_600_000_000_000_000_000
            for p in (unchanged, changed):
                os.utime(p, ns=(old, old))
            manifest = target/'.cmux-testbox-source-mtimes.tsv'
            subprocess.run(['python3', helper, 'record', str(source), str(manifest)], check=True)
            changed.write_text('new')
            os.utime(unchanged, ns=(old+1_000_000_000, old+1_000_000_000))
            changed_time = changed.stat().st_mtime_ns
            subprocess.run(['python3', helper, 'restore', str(source), str(manifest)], check=True)
            self.assertEqual(unchanged.stat().st_mtime_ns, old)
            self.assertEqual(changed.stat().st_mtime_ns, changed_time)


if __name__ == '__main__':
    unittest.main()
