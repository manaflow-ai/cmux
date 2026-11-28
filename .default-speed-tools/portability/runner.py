#!/usr/bin/env python3
"""Emit managed-job scripts and commands. This program NEVER dispatches or uploads."""
import argparse
import base64
import json
from pathlib import Path
import re
import shlex
import sys

from worker import PART_BYTES, digest, STOP_TREE_MEASURE_SHA256, STOP_TREE_SOURCE_SHA256

CLIENT = '/home/cmux/.local/share/cmux-fleet-client/current/ci.sh'


def source_config(status, sha, root):
    if status.get('state') not in ('done', 'failed', 'cancelled'):
        raise ValueError('study must be terminal before reusing its workspace')
    if not re.fullmatch('[0-9a-f]{40}', sha):
        raise ValueError('full source SHA required')
    if not status.get('id') or not status.get('workspace'):
        raise ValueError('need controller job identity/workspace')
    inputs = status.get('inputs', {})
    if not inputs or any(not re.fullmatch(r'src\.\d{3}', k) or not re.fullmatch(r'sha256:[0-9a-f]{64}', v) for k, v in inputs.items()):
        raise ValueError('need existing sparse src.NNN inputs only; never repack')
    names = sorted(inputs)
    if names != [f'src.{i:03d}' for i in range(len(names))]:
        raise ValueError('source input sequence has a gap')
    outer = shlex.split(status['command'])
    if outer[:3] != ['exec', '/bin/bash', '-c'] or len(outer) != 4:
        raise ValueError('unrecognized fleet job script')
    lines = outer[3].splitlines()
    sparse = [shlex.split(line) for line in lines if line.startswith('git sparse-checkout set --no-cone -- ')]
    checkout = [shlex.split(line) for line in lines if line.startswith('git -c core.hooksPath=/dev/null checkout ')]
    if len(sparse) != 1 or len(checkout) != 1 or checkout[0][-1] != sha:
        raise ValueError('source SHA or sparse checkout metadata mismatch')
    patterns = sparse[0][5:]
    if not patterns or patterns[0] != '/*':
        raise ValueError('unsupported sparse patterns')
    if not re.fullmatch(r'/tmp/cmux-cache-portability-[a-zA-Z0-9-]+', root):
        raise ValueError('root must be a task-private /tmp/cmux-cache-portability-NAME')
    return dict(sha=sha, source_job=status['id'], workspace=status['workspace'], source_inputs=inputs,
                patterns=patterns, root=root)


def shell(config):
    worker = Path(__file__).with_name('worker.py').read_bytes()
    # Both worker and config are literal bytes, not shell-interpolated source.
    payload = base64.b64encode(worker).decode()
    launch = "import base64; exec(compile(base64.b64decode("+repr(payload)+"), '<portability-worker>', 'exec'))"
    return '#!/usr/bin/env bash\nset -euo pipefail\nexec python3 -c '+shlex.quote(launch)+' '+shlex.quote(json.dumps(config, separators=(',', ':')))+'\n'


def write_plan(config, output):
    output.mkdir(parents=True, exist_ok=False)
    config = dict(config, worker_sha256=digest(Path(__file__).with_name('worker.py')),
                  stop_tree_measure_sha256=STOP_TREE_MEASURE_SHA256, stop_tree_source_sha256=STOP_TREE_SOURCE_SHA256)
    mode = config['mode']
    script = output/(mode+'.sh')
    script.write_text(shell(config))
    config_path = output/'config.json'
    config_path.write_text(json.dumps(config, indent=2)+'\n')
    inputs = dict(config['source_inputs'])
    upload = []
    if mode == 'consumer':
        for part in config['cache_manifest']['parts']:
            inputs[part['name']] = 'sha256:'+part['sha256']
            upload.append(shlex.join(['bash', CLIENT, 'artifact-put', str(Path(config['producer_directory'])/part['name']),
                                      '--sha256', part['sha256'], '--lane', config['workspace']]))
    request = 'portability-'+mode+'-'+digest(config_path)[:24]
    args = ['bash', CLIENT, 'submit', '--kind', 'fast-checks', '--label', 'cmux-next-linux', '--workspace', config['workspace'],
            '--request-key', request,
            '--receipt', str(output/'submit-receipt.json'), '--artifact', 'artifacts/portability.tgz']
    for name, value in sorted(inputs.items()):
        args += ['--input', name+'='+value]
    # Script text is embedded as one argv argument; no shell command substitution.
    args += ['--command', 'exec /bin/bash -c '+shlex.quote(script.read_text())]
    if len(args[-1].encode()) > 120_000:
        raise ValueError('job command exceeds safe argv size; no upload or submit occurred')
    commands = '# Review before executing. No network operations occurred while generating this file.\n'
    commands += '\n'.join(upload+[shlex.join(args)])+'\n'
    (output/'commands.sh').write_text(commands)
    print(json.dumps({'mode': mode, 'source_sha': config['sha'], 'source_job': config['source_job'],
                      'request_key': request, 'script': str(script), 'commands': str(output/'commands.sh')}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='mode', required=True)
    producer = sub.add_parser('producer')
    producer.add_argument('--study-status', required=True, type=Path)
    producer.add_argument('--sha', required=True)
    producer.add_argument('--root', required=True)
    producer.add_argument('--output', required=True, type=Path)
    consumer = sub.add_parser('consumer')
    consumer.add_argument('--producer-config', required=True, type=Path)
    consumer.add_argument('--producer-directory', required=True, type=Path)
    consumer.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.mode == 'producer':
        config = source_config(json.loads(args.study_status.read_text()), args.sha, args.root)
    else:
        config = json.loads(args.producer_config.read_text())
        directory = args.producer_directory.resolve()
        exit_receipt = json.loads((directory/'exit.json').read_text())
        if exit_receipt != dict(exit_code=0, mode='producer', source_sha=config['sha']):
            raise ValueError('producer did not complete successfully at this exact source')
        manifest = json.loads((directory/'cache-manifest.json').read_text())
        if manifest['identity']['sha'] != config['sha'] or manifest['identity']['root'] != config['root']:
            raise ValueError('producer identity mismatch')
        parts = manifest['parts']
        if not parts or [p['name'] for p in parts] != [f'cache.{i:03d}' for i in range(len(parts))]:
            raise ValueError('invalid archive parts')
        if sum(p['bytes'] for p in parts) != manifest['archive_bytes']:
            raise ValueError('archive byte count mismatch')
        for part in parts:
            p = directory/part['name']
            if not 0 < part['bytes'] <= PART_BYTES or p.stat().st_size != part['bytes'] or digest(p) != part['sha256']:
                raise ValueError('invalid archive part digest/size')
        config.update(cache_manifest=manifest, producer_directory=str(directory))
    config['mode'] = args.mode
    write_plan(config, args.output.resolve())


if __name__ == '__main__':
    main()
