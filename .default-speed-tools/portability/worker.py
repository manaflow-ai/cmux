#!/usr/bin/env python3
"""Task-local managed worker. Never publish to R2; never reuse a live target."""
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import select
import shlex
import shutil
import signal
import subprocess
import sys
import time
import tomllib

PART_BYTES = 400 * 1024 * 1024
FAILURE_TAIL_BYTES = 16 * 1024


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for data in iter(lambda: f.read(1024 * 1024), b''):
            h.update(data)
    return h.hexdigest()


def split_archive(path, destination, limit=PART_BYTES):
    result = []
    with Path(path).open('rb') as source:
        while True:
            data = source.read(limit)
            if not data:
                break
            part = destination / f'cache.{len(result):03d}'
            part.write_bytes(data)
            result.append({'name': part.name, 'bytes': len(data), 'sha256': digest(part)})
    return result


def native_hashes(target):
    paths = []
    for sub in ('build', '.fingerprint', 'deps'):
        for item in (target / 'debug' / sub).glob('*'):
            if 'ghostty_vt_sys-' in item.name or 'ghostty-vt-sys-' in item.name:
                paths.extend([item] if item.is_file() else [p for p in item.rglob('*') if p.is_file()])
    result = {str(p.relative_to(target)): digest(p) for p in sorted(paths)}
    if not result or not any('libghostty-vt.a' in p for p in result):
        raise RuntimeError('no complete ghostty-vt-sys native output found')
    return result


def retained_dependency_hashes(target):
    """Fingerprint and compiled outputs for the native crate's workspace build dependency."""
    paths = []
    for sub in ('build', '.fingerprint', 'deps'):
        for item in (target / 'debug' / sub).glob('*'):
            if re.match(r'(?:lib)?cmux[-_]transport[-_]rewrite-', item.name):
                paths.extend([item] if item.is_file() else [p for p in item.rglob('*') if p.is_file()])
    result = {str(p.relative_to(target)): digest(p) for p in sorted(paths)}
    if (not any(p.startswith('debug/.fingerprint/') for p in result)
            or not any(p.startswith('debug/deps/libcmux_transport_rewrite-') and p.endswith('.rlib') for p in result)):
        raise RuntimeError('no complete cmux-transport-rewrite dependency output found')
    return result


def prune_command(src, target, metadata):
    return ['python3', '-I', str(src/'scripts/ci/cargo_target_strip.py'), str(target),
            '--cargo-metadata', str(metadata), '--keep', 'ghostty-vt-sys', 'cmux-transport-rewrite']


def fresh(log):
    return ('Fresh ghostty-vt-sys v' in log and 'Compiling ghostty-vt-sys' not in log
            and not re.search(r'Running .*ghostty-vt-sys[^\n]*build-script', log))


# Exact ownership implementation embedded from production measure.py.
STOP_TREE_MEASURE_SHA256 = '41f947c6894c9b7514ae26ec7a0045e62782cc4d23ad4c632057a72638e8ac78'
STOP_TREE_SOURCE_SHA256 = '61d9ba53e937ef4aebb2d93389af6c20dd9f9f09574e95d4383fa4932248a556'

def stop_tree(pid):
    """Stop only this child tree; retain the CI step's group for outer cancellation."""
    stopped = {}
    stop_deadline = time.monotonic() + 5
    def visit(child):
        if child in stopped:
            return
        try:
            descriptor = os.pidfd_open(child)
        except ProcessLookupError:
            return
        stopped[child] = descriptor
        try:
            signal.pidfd_send_signal(descriptor, signal.SIGSTOP)
        except ProcessLookupError:
            return
        tasks = Path("/proc") / str(child) / "task"
        # Delivery is asynchronous: every thread must acknowledge the group stop
        # before its child list is stable. Exited tasks need no acknowledgement.
        while True:
            states = []
            for task in tasks.glob("*/stat"):
                try:
                    states.append(task.read_text().rsplit(")", 1)[1].split()[0])
                except FileNotFoundError:
                    continue
            if all(state in {"T", "t", "Z", "X"} for state in states):
                break
            if time.monotonic() >= stop_deadline:
                raise RuntimeError("owned process tree did not stop within 5 seconds")
            time.sleep(0.001)
        for task in tasks.glob("*/children"):
            try:
                children = task.read_text().split()
            except FileNotFoundError:
                continue
            for descendant in children:
                visit(int(descendant))
    def kill_and_wait():
        pending = select.poll()
        for descriptor in reversed(list(stopped.values())):
            pending.register(descriptor, select.POLLIN)
            try:
                signal.pidfd_send_signal(descriptor, signal.SIGKILL)
            except ProcessLookupError:
                pass
        # SIGKILL delivery is asynchronous. Wait for kernel exit notifications,
        # including non-child descendants, without mistaking a reused PID for ours.
        remaining = set(stopped.values())
        deadline = time.monotonic() + 5
        while remaining:
            milliseconds = max(0, int((deadline - time.monotonic()) * 1000))
            if not milliseconds:
                raise RuntimeError("owned process tree did not exit within 5 seconds")
            for descriptor, _events in pending.poll(milliseconds):
                pending.unregister(descriptor)
                remaining.remove(descriptor)
    try:
        visit(pid)
    finally:
        try:
            kill_and_wait()
        finally:
            for descriptor in stopped.values():
                os.close(descriptor)


class RunFailure(Exception):
    def __init__(self, code):
        self.code = code


def failure_log_tail(path):
    with path.open('rb') as log:
        size = log.seek(0, os.SEEK_END)
        log.seek(max(0, size - FAILURE_TAIL_BYTES))
        tail = log.read(FAILURE_TAIL_BYTES)
    return dict(log_bytes=size, tail_bytes=len(tail), truncated=size > len(tail),
                tail=tail.decode('utf-8', errors='replace'))


def cargo_command(tools, mode):
    args = [str(tools/'cargo'), 'build', '--locked', '--profile', 'dev', '-p', 'ghostty-vt',
            '--features', 'phone-speed', '--example', 'phone_default_speed', '-vv']
    if mode == 'consumer':
        args.append('--offline')
    return args


def run_step(name, args, out, env, timings, cwd, timeout=600, stdin=None):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    timed_out, cancelled_signal, cleanup_error = False, None, None
    rc = None
    with (out / (name + '.log')).open('wb') as log:
        # Inherit the fleet step's process group so its cancellation still reaches us.
        proc = subprocess.Popen(args, cwd=cwd, env=env, stdout=log,
                                stderr=subprocess.STDOUT, stdin=stdin)

        def cleanup():
            nonlocal cleanup_error
            try:
                stop_tree(proc.pid)
                proc.wait(timeout=5)
            except Exception as error:
                cleanup_error = repr(error)

        def cancelled(signum, _frame):
            nonlocal cancelled_signal, rc
            cancelled_signal = signum
            rc = 128 + signum
            if proc.poll() is None:
                cleanup()
            raise RunFailure(rc)

        previous = signal.signal(signal.SIGTERM, cancelled)
        try:
            try:
                rc = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out, rc = True, 124
                cleanup()
        finally:
            signal.signal(signal.SIGTERM, previous)
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            receipt = dict(name=name, argv=args, exit_code=rc, process_exit_code=proc.poll(),
                           cwd=str(cwd), timeout_seconds=timeout,
                           timeout=timed_out, cancelled_signal=cancelled_signal, cleanup_error=cleanup_error,
                           wall_seconds=time.monotonic()-start, user_seconds=after.ru_utime-before.ru_utime,
                           system_seconds=after.ru_stime-before.ru_stime,
                           cpu_complete=not timed_out and cancelled_signal is None and cleanup_error is None)
            timings.append(receipt)
            (out / 'timings.json').write_text(json.dumps(timings, indent=2)+'\n')
            print(json.dumps(receipt), flush=True)
            if rc:
                log.flush()
                try:
                    diagnostic = failure_log_tail(out / (name + '.log'))
                except OSError as error:
                    diagnostic = {'log_read_error': repr(error)}
                print(json.dumps(dict(event='failed_step_log', name=name, **diagnostic)), flush=True)
    if rc:
        raise RunFailure(rc if rc > 0 else 128-rc)
    return (out / (name + '.log')).read_text(errors='replace')


def main(config):
    overall_start = time.monotonic()
    overall_cpu = time.process_time()
    job = Path.cwd().resolve()
    root = Path(config['root'])
    if not re.fullmatch(r'/tmp/cmux-cache-portability-[a-zA-Z0-9-]+', str(root)):
        raise ValueError('invalid task-private root')
    out = job / 'portability-output'
    out.mkdir(exist_ok=False)
    env = dict(os.environ)
    for key in list(env):
        if re.search(r'TOKEN|SECRET|PASSWORD|CREDENTIAL|_PAT$|^GH_|^GITHUB_|^GIT_CONFIG_|ASKPASS', key):
            env.pop(key)
        elif key.startswith(('CARGO_', 'RUST', 'CMUX_ZIG', 'CMUX_GHOSTTY', 'ZIG_')) or key in ('CC', 'CXX', 'CFLAGS', 'CXXFLAGS', 'LDFLAGS'):
            env.pop(key)
    for key in ('RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER', 'ZIG', 'CMUX_ZIG', 'SSH_AUTH_SOCK'):
        env.pop(key, None)
    env.update(RUSTUP_HOME='/home/cmux/.rustup', CARGO_HOME='/home/cmux/.cache/fast-checks/cargo',
               PATH='/home/cmux/.cargo/bin:/opt/zig-0.17.0:/usr/local/bin:/usr/bin:/bin',
               GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_TERMINAL_PROMPT='0',
               GIT_SSH_COMMAND='ssh -F /dev/null -o IdentitiesOnly=yes -o IdentityFile=/dev/null -o IdentityAgent=none -o BatchMode=yes',
               CMUX_GHOSTTY_VT_ZIG_CPU='baseline', CMUX_GHOSTTY_SRC='', CARGO_INCREMENTAL='0',
               CMUX_ZIG_MIRROR_ONLY='1', ZIG_GLOBAL_CACHE_DIR=str(root / 'zig-cache'))
    code, created = 1, False
    timings = []

    def run(name, args, cwd=None, timeout=600, stdin=None):
        return run_step(name, args, out, env, timings, cwd or root, timeout, stdin)

    try:
        root.mkdir(exist_ok=False)
        created = True
        src = root / 'src'
        target = src / 'cmux-tui/target'
        env['CARGO_TARGET_DIR'] = str(target)
        parts = []
        for name, expected in sorted(config['source_inputs'].items()):
            p = job / 'inputs' / name
            if digest(p) != expected.removeprefix('sha256:'):
                raise RuntimeError('source input digest mismatch: '+name)
            parts.append(p)
        run('git-init', ['git', 'init', '-q', str(src)])
        run('source-index', ['bash', '-o', 'pipefail', '-c', 'cat '+shlex.join(map(str, parts))+' | git index-pack --stdin'], cwd=src)
        for pack in (src / '.git/objects/pack').glob('*.pack'):
            pack.with_suffix('.promisor').touch()
        (src / '.git/shallow').write_text(config['sha']+'\n')
        for key, value in [('core.repositoryformatversion', '1'), ('extensions.partialClone', 'origin'),
                           ('remote.origin.url', str(root/'no-promisor-remote')), ('remote.origin.promisor', 'true')]:
            run('git-config-'+key, ['git', 'config', key, value], cwd=src)
        run('sparse', ['git', 'sparse-checkout', 'set', '--no-cone', '--', *config['patterns']], cwd=src)
        run('checkout', ['git', '-c', 'core.hooksPath=/dev/null', 'checkout', '-q', '--detach', config['sha']], cwd=src)
        run('ghostty', ['git', 'submodule', 'update', '--init', '--depth=1', 'ghostty-next'], cwd=src, timeout=600)
        ghostty = run('ghostty-head', ['git', 'rev-parse', 'HEAD:ghostty-next'], cwd=src).strip()
        actual = run('ghostty-checkout', ['git', 'rev-parse', 'HEAD'], cwd=src/'ghostty-next').strip()
        if actual != ghostty:
            raise RuntimeError('ghostty gitlink mismatch')
        tools = root / 'tools'
        tools.mkdir()
        identities = {}
        channel = tomllib.loads((src/'cmux-tui/rust-toolchain.toml').read_text())['toolchain']['channel']
        if not re.fullmatch(r'\d+\.\d+\.\d+', channel):
            raise RuntimeError('only an exact pinned Rust release is supported')
        for tool in ('cargo', 'rustc', 'rustdoc'):
            # Never invoke a rustup proxy or installer (including implicit rustc/rustdoc).
            binary = Path(env['RUSTUP_HOME'])/'toolchains'/(channel+'-x86_64-unknown-linux-gnu')/'bin'/tool
            (tools/tool).symlink_to(binary)
            identities[tool] = {'path': str(binary), 'sha256': digest(binary)}
        env['RUSTC'] = identities['rustc']['path']
        env['RUSTDOC'] = identities['rustdoc']['path']
        # Owning CI helper verifies the tarball/version and applies its reviewed std patch.
        # GITHUB_ENV here is only its local output file, never a trusted Actions identity.
        zig_output = root/'zig-env'
        env.update(GHOSTTY_ZIG_SOURCE='ghostty-next', ZIG_FORCE_LOCAL_INSTALL='1',
                   ZIG_INSTALL_ROOT=str(tools/'zig-installed'), RUNNER_TEMP=str(root/'zig-setup'),
                   GITHUB_ENV=str(zig_output))
        run('setup-zig', ['bash', str(src/'scripts/install-zig-ci.sh')], cwd=src, timeout=600)
        selected = [line.split('=', 1)[1] for line in zig_output.read_text().splitlines() if line.startswith('CMUX_ZIG=')]
        if len(selected) != 1:
            raise RuntimeError('owning Zig setup did not return one compiler')
        selected_root = Path(selected[0]).parent.resolve()
        stable_zig = tools/'zig-tree'
        # The owning helper may return /opt's already-reviewed copy. Never modify it.
        if selected_root.is_relative_to(root):
            selected_root.rename(stable_zig)
        else:
            shutil.copytree(selected_root, stable_zig)
        for name in ('GHOSTTY_ZIG_SOURCE', 'ZIG_FORCE_LOCAL_INSTALL', 'ZIG_INSTALL_ROOT', 'RUNNER_TEMP', 'GITHUB_ENV'):
            env.pop(name, None)
        zig = stable_zig/'zig'
        (tools/'zig').symlink_to(zig)
        identities['zig'] = {'path': str(zig), 'sha256': digest(zig)}
        # Include every Zig std file: a patched lib must match too, not only its executable.
        zig_lib = {str(p.relative_to(zig.parent)): digest(p) for p in sorted((zig.parent/'lib').rglob('*')) if p.is_file()}
        identities['zig_lib'] = {'files': len(zig_lib), 'sha256': hashlib.sha256(json.dumps(zig_lib, sort_keys=True).encode()).hexdigest()}
        identities['cargo_config'] = {name: digest(Path(env['CARGO_HOME'])/name)
                                      for name in ('config', 'config.toml') if (Path(env['CARGO_HOME'])/name).is_file()}
        for tool in ('cc', 'ld'):
            binary = Path(shutil.which(tool, path=env['PATH'])).resolve()
            identities[tool] = {'path': str(binary), 'sha256': digest(binary)}
        identities['platform'] = {'machine': os.uname().machine, 'os_release': Path('/etc/os-release').read_text(),
                                  'libc': run('libc-version', ['ldd', '--version']).splitlines()[0]}
        env['PATH'] = str(tools)+':'+env['PATH']
        version = run('zig-version', [str(tools/'zig'), 'version']).strip()
        zon = (src/'ghostty-next/build.zig.zon').read_text()
        wanted = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', zon).group(1)
        if version != wanted:
            raise RuntimeError(f'fleet Zig {version} != pinned {wanted}; no build attempted')
        if wanted == '0.17.0':
            installer = (src/'scripts/install-zig-ci.sh').read_text()
            expected_patch = re.search(r'ZIG_STD_PATCH_TO="([0-9a-f]{64})"', installer).group(1)
            if digest(stable_zig/'lib/std/Io/Threaded.zig') != expected_patch:
                raise RuntimeError('Zig std patch differs from owning CI helper')
        identity = dict(sha=config['sha'], ghostty=ghostty, root=str(root), source=str(src), target=str(target),
                        tools=identities, environment={k: env.get(k) for k in ('CARGO_HOME', 'RUSTUP_HOME', 'PATH',
                        'CARGO_TARGET_DIR', 'CARGO_INCREMENTAL', 'CMUX_GHOSTTY_VT_ZIG_CPU', 'CMUX_GHOSTTY_SRC',
                        'CMUX_ZIG_MIRROR_ONLY', 'ZIG', 'CMUX_ZIG', 'RUSTC', 'RUSTDOC')})
        (out/'identity.json').write_text(json.dumps(identity, indent=2)+'\n')
        cargo = cargo_command(tools, config['mode'])
        manifest = target/'.cmux-testbox-source-mtimes.tsv'
        if config['mode'] == 'producer':
            if target.exists():
                raise RuntimeError('cold target already exists')
            run('cold-build', cargo, cwd=src/'cmux-tui', timeout=1800)
            before = native_hashes(target)
            dependencies_before = retained_dependency_hashes(target)
            meta = run('metadata', [str(tools/'cargo'), 'metadata', '--no-deps', '--format-version', '1'], cwd=src/'cmux-tui')
            metadata_path = out/'cargo-metadata.json'
            metadata_path.write_text(meta)
            # Exact production pruning arguments; force the pruning branch without spoofing a trusted push.
            entries_before = {str(p.relative_to(target)) for p in target.rglob('*') if p.is_file()}
            run('prune', prune_command(src, target, metadata_path))
            removed = entries_before - {str(p.relative_to(target)) for p in target.rglob('*') if p.is_file()}
            if not removed or native_hashes(target) != before:
                raise RuntimeError('prune removed no workspace output or changed native output')
            if retained_dependency_hashes(target) != dependencies_before:
                raise RuntimeError('prune changed retained build dependency output')
            (out/'pruned-files.json').write_text(json.dumps(sorted(removed), indent=2)+'\n')
            run('record-mtimes', ['python3', '-I', str(src/'scripts/blacksmith-testbox-source-mtimes.py'), 'record', str(src), str(manifest)])
            if not manifest.is_file() or not manifest.stat().st_size:
                raise RuntimeError('source mtime manifest missing')
            archive = out/'target.tar.zst'
            run('archive', ['bash', '-o', 'pipefail', '-c', 'tar -cf - -C '+shlex.quote(str(target))+' . | zstd -T0 -3 -q -o '+shlex.quote(str(archive))], timeout=900)
            receipt = dict(identity=identity, native_hashes=before, retained_dependency_hashes=dependencies_before,
                           archive_sha256=digest(archive),
                           archive_bytes=archive.stat().st_size, manifest_sha256=digest(manifest),
                           target_bytes=sum(p.stat().st_size for p in target.rglob('*') if p.is_file()),
                           parts=split_archive(archive, out))
            (out/'cache-manifest.json').write_text(json.dumps(receipt, indent=2)+'\n')
            archive.unlink()  # Own redundant whole archive; exported parts are the exact same bytes.
        else:
            receipt = config['cache_manifest']
            if identity != receipt['identity']:
                raise RuntimeError('producer/consumer path, tool or environment mismatch')
            env['CARGO_LOG'] = 'cargo::core::compiler::fingerprint=info'
            if target.exists():
                raise RuntimeError('consumer target exists before restore')
            archive = root/'target.tar.zst'
            with archive.open('wb') as dest:
                for part in receipt['parts']:
                    p = job/'inputs'/part['name']
                    if p.stat().st_size != part['bytes'] or digest(p) != part['sha256']:
                        raise RuntimeError('cache part mismatch')
                    with p.open('rb') as source:
                        shutil.copyfileobj(source, dest)
            if digest(archive) != receipt['archive_sha256']:
                raise RuntimeError('cache archive mismatch')
            target.mkdir(parents=True)
            run('unpack', ['bash', '-o', 'pipefail', '-c', 'zstd -dc '+shlex.quote(str(archive))+' | tar -xf - -C '+shlex.quote(str(target))], timeout=900)
            if digest(manifest) != receipt['manifest_sha256']:
                raise RuntimeError('source manifest mismatch')
            run('restore-mtimes', ['python3', '-I', str(src/'scripts/blacksmith-testbox-source-mtimes.py'), 'restore', str(src), str(manifest)])
            manifest.unlink()
            if native_hashes(target) != receipt['native_hashes']:
                raise RuntimeError('restored native hashes mismatch')
            if retained_dependency_hashes(target) != receipt['retained_dependency_hashes']:
                raise RuntimeError('restored build dependency hashes mismatch')
            log = run('first-consumer-build', cargo, cwd=src/'cmux-tui', timeout=60)
            if not fresh(log) or timings[-1]['wall_seconds'] > 60 or native_hashes(target) != receipt['native_hashes']:
                raise RuntimeError('first consumer native reuse/60-second acceptance failed')
            if retained_dependency_hashes(target) != receipt['retained_dependency_hashes']:
                raise RuntimeError('first consumer changed retained build dependency output')
            (out/'accepted.json').write_text(json.dumps({'fresh': True, 'unchanged_native_hashes': True,
                'unchanged_retained_dependency_hashes': True, 'first_build': timings[-1]}, indent=2)+'\n')
        code = 0
    except RunFailure as error:
        code = error.code
    except Exception as error:
        (out/'error.txt').write_text(repr(error)+'\n')
        print(repr(error), file=sys.stderr)
    finally:
        (out/'exit.json').write_text(json.dumps({'exit_code': code, 'mode': config['mode'], 'source_sha': config['sha']})+'\n')
        usage = resource.getrusage(resource.RUSAGE_CHILDREN)
        (out/'overall.json').write_text(json.dumps({'wall_seconds': time.monotonic()-overall_start,
            'worker_cpu_seconds': time.process_time()-overall_cpu, 'child_user_seconds': usage.ru_utime,
            'child_system_seconds': usage.ru_stime})+'\n')
        if created:
            shutil.rmtree(root)  # Only the root this invocation created with exist_ok=False.
        (job/'artifacts').mkdir(exist_ok=True)
        # Preserve worker failure even if artifact packaging also fails.
        packed = subprocess.run(['tar', '-czf', str(job/'artifacts/portability.tgz'), '-C', str(out), '.'], timeout=900)
        if code == 0 and packed.returncode:
            code = packed.returncode
    return code


if __name__ == '__main__':
    raise SystemExit(main(json.loads(sys.argv[1])))
