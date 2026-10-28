from pathlib import Path
import os, subprocess
root=Path.cwd().parent
files=[root/'webviews/src/agent-session/acpmux/threadMinimap'/name for name in ['ThreadMinimap.tsx','threadMinimap.css']]
head=[p.read_bytes() for p in files]
try:
 for version in ['before','after']:
  for p,data in zip(files,head): p.write_bytes((root/'.rail-speed-evidence/base'/f'{p.stem}.txt').read_bytes() if version=='before' else data)
  for paged in [False,True]:
   case=f'{version}-'+('paged' if paged else 'loaded')
   print(f'RAIL_PAIR_START {case}',flush=True)
   subprocess.run(['bun','bench/thread-rail-jump.bench.ts','1200','20'],check=True,env={**os.environ,'RAIL_BENCH_OUT':f'/tmp/rail-speed-evidence/{case}','RAIL_BENCH_EXPORT':'1','RAIL_BENCH_BASE':'39d216bc7f9fa90ca804d9e5b78bcd7db1cbd3ad','RAIL_BENCH_HEAD':'39d216bc7f9fa90ca804d9e5b78bcd7db1cbd3ad' if version=='before' else subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'RAIL_BENCH_PAGED':'1' if paged else '0'})
   print(f'RAIL_PAIR_END {case}',flush=True)
finally:
 for p,data in zip(files,head): p.write_bytes(data)
