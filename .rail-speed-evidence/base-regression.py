from pathlib import Path
import os, subprocess
root=Path.cwd().parent
files=[root/'webviews/src/agent-session/acpmux/threadMinimap'/name for name in ['ThreadMinimap.tsx','threadMinimap.css']]
head=[p.read_bytes() for p in files]
try:
 for p in files: p.write_bytes((root/'.rail-speed-evidence/base'/f'{p.stem}.txt').read_bytes())
 done=subprocess.run(['bun','test','test/thread-rail-scroll-entrance.test.ts'],env={**os.environ,'CMUX_BROWSER_TESTS':'1'},text=True,capture_output=True)
 print(done.stdout,done.stderr)
 if done.returncode==0 or 'existing ticks draw immediately' not in done.stderr or 'toBeGreaterThanOrEqual' not in done.stderr:
  raise SystemExit('Expected base failure from replayed entrance was not observed')
 print('RAIL_BASE_REGRESSION expected entrance failure reproduced')
finally:
 for p,data in zip(files,head): p.write_bytes(data)
