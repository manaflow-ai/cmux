from pathlib import Path
import os
import subprocess

root = Path.cwd()
source = root / 'scripts/bench/phone-default-speed/src/main.rs'
clean = source.read_text()
env = dict(os.environ)
env['PATH'] = str(root / '.default-speed-tools/bin') + ':' + env['PATH']
env['CARGO_TARGET_DIR'] = str(root / 'scripts/bench/phone-default-speed/target')
env['VALGRIND_INCLUDE'] = str(root / '.default-speed-tools/valgrind-root/usr/include')
env['CMUX_GHOSTTY_VT_ZIG_CPU'] = 'baseline'
manifest = 'scripts/bench/phone-default-speed/Cargo.toml'
binary = root / 'scripts/bench/phone-default-speed/target/release/cmux-phone-default-speed'

def build():
    subprocess.run(['cargo', '+1.95.0', 'build', '--release', '--locked', '--manifest-path', manifest], env=env, check=True, timeout=180)

try:
    marker = 'let runs = frame.runs();'
    assert clean.count(marker) == 1
    source.write_text(clean.replace(marker, 'black_box(frame.runs());\n        black_box(frame.runs());\n        ' + marker))
    build()
    result = subprocess.run([str(binary), 'check'], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    print('EXTRA RENDER WORK EXIT:', result.returncode, '\n', result.stdout, flush=True)
    assert result.returncode != 0 and 'exceeds' in result.stdout, 'extra render work did not trip instruction budget'
    begin = clean.index('        match operation {')
    end = clean.index('        render\n', begin)
    source.write_text(clean[:begin] + '        black_box(operation);\n' + clean[end:])
    build()
    for case in ('primary-100', 'alternate-100'):
        result = subprocess.run([str(binary), 'case', case], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        print('NO DECODE', case, 'EXIT:', result.returncode, '\n', result.stdout, flush=True)
        assert result.returncode != 0 and 'assertion' in result.stdout, 'no-op updates passed final-frame validation'
finally:
    source.write_text(clean)
    build()
subprocess.run([str(binary), 'check'], env=env, check=True, timeout=180)
print('PASS: expensive-work and no-op mutations rejected; restored source passes', flush=True)
