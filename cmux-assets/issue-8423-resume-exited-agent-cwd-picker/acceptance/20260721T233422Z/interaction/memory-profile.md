# Tagged-app and host memory profile

All app measurements target only bundle `com.cmuxterm.app.debug.issue.8423.resume.exited.agent.cwd.picker`. RSS values are from `ps`.

## Tagged app samples

| State | PID | RSS KiB | CPU |
|---|---:|---:|---:|
| Before exact stale restart #1 | 26711 | 167424 | 0.1% |
| Early after restart #1 | 84294 | 205504 | 2.8% |
| After first shell interaction | 84294 | 238896 | 0.1% |
| Before restart #2 | 84294 | 158720 | 0.0% |
| Early after restart #2 | 13887 | 160432 | 0.0% |
| Later idle sample 1 | 31494 | 260704 | 2.5% |
| Later idle sample 2 (+10s) | 31494 | 239792 | 3.6% |
| Later idle sample 3 (+20s) | 31494 | 237648 | 0.5% |
| Final idle (+41s) | 31494 | 213584 | 3.3% instantaneous |

The post-interaction RSS declined from 260704 KiB to 213584 KiB over the observed idle window. This short sample does not prove absence of every leak, but it shows no monotonic tagged-app growth across the exercised restart path.

At the final sample, the tagged app's sanitized descendant tree contained only two `/usr/bin/login` processes and two `zsh` shells. It contained no Codex process, Codex resume process, or surface-resume launcher.

## Host-wide build pressure

Initial host snapshot:

- Physical RAM: 38,654,705,664 bytes (~36 GiB)
- Swap: 5,058.62 MiB used of 6,144 MiB
- Compressor: 1,033,736 pages at 16 KiB/page (~15.77 GiB)
- Concurrent compiler pool: 7 `xcodebuild`, 43 `swift-frontend`
- Tagged app RSS at that time: 197,824 KiB

Final host snapshot:

- Swap: 6,384.44 MiB used of 7,168 MiB
- Compressor: 904,708 pages at 16 KiB/page (~13.80 GiB)
- Concurrent compiler pool: 7 `xcodebuild`, 19 `swift-frontend`
- `memory_pressure -Q`: 47% system-wide memory free

Interpretation: the large swap/compression footprint and dozens of active Swift compiler workers are host-wide build pressure. The tagged app stayed around 155-255 MiB RSS and released memory during idle, so this evidence does not implicate the PR's runtime path as the source of the multi-gigabyte pressure. No other agent's build process was killed or cleaned up.
