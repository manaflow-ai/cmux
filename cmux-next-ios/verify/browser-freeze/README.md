# Browser freeze soak (2026-10-24)

The user's report: "In a browser view on iOS, after 3-5 minutes of usage it stopped
responding to my gestures and the displayed browser rendering was no longer being
updated." The host log of that run shows the phone asking for keyframes about 4 times a
second for 7 minutes while the Mac kept sending frames (verify/browser-freeze.md).

`brfz_soak.py` reproduces it on the rig and measures it. Results are in `results.md`.

## Rig

- **Phone.** A TestFlight-configuration simulator app (`dev.cmux.app.internal`,
  production Worker, Cloudflare TURN) in the headless simulator `cmux-brfz` (iPhone 17
  Pro, iOS 26.5) on mini-cmux8s. It is signed in to production test account B
  (`~/.secrets/brfz-prod.creds` on the mini, 0600, `EMAIL=`/`PASSWORD=`, the laptop's
  `~/.secrets/cnx-ios-userhub-verify/B.creds`) with the simulator-only password sign-in.
  The production dogfood account (`cmuxterm-prod.env`) does not work for this: its
  password sign-in fails with `StackAuthError`.
- **Mac.** A hidden rig Mac app on mini-cmux11s in `~/brfreeze-rig` (moved from mini-cmux9s, whose load of 230 kept the browser host from starting) (rig.py, the
  `cmux-next-ios/verify/e2e` tooling of the base, the fleet app in `src/`). It is the fleet `--production` app `cmux-mobile-e2e-lrbase` (hostd 36289e3cd3, whose media/ and
  hybrid.rs code equals bb9c03bf; a fresh fleet build of ec101239 sat queued for an hour with every
  worker paused and was cancelled). For a Mac-side fix, use a fleet
  `--production` build, signed in to the same account B, settings only through
  `open --env`. Its hostd logs through the `LINKREL_HOSTD_LOG` wrapper. The loss
  configuration writes `video-drop-permille` into hostd's state folder, which takes
  effect on the next link without a restart.
- **Link.** Real Worker signaling and Cloudflare TURN. No local socket, loopback or
  direct shortcut.
- **Driver.** `brfz_soak.py` on mini-cmux8s, run through `relay.py` from the laptop
  (the minis cannot ssh to each other). It opens the rig's terminal workspace to bring
  up the link. Then it opens browser tab A (en.wikipedia.org) and keeps using it for
  2.5 min. It opens tab B (news.ycombinator.com, its own browser host process with a
  capture clock 2.5 min behind A's) and uses it for 1 min. It idles on the workspace list
  for 45 s, longer than the media session's 30 s linger, so the lane moves route, then
  goes back to B. After that it switches tabs, opens tab C (duckduckgo.com), optionally
  backgrounds the app, idles for a minute, and switches A, B and C again. The run lasts
  about 14 min. The interaction is scrolls, taps on links, back and forward, and search:
  a marker typed into the page's search box, or a search URL typed into the address bar.
- **Measured.**
  - Phone frames: the app's `browser <tab>: N fps ... via <carrier>` os_log line. It is
    logged once per 30 shown frames, so each line stands for 30 decoded frames.
  - `decode failed` lines.
  - Input round trip: from the gesture until the page area of a fresh screenshot
    changes, or for a search until OCR finds the marker.
  - The rig's `browser: media lane ... keyframe_requests=` reports (every 5 s) and its
    route and lane lines.
- **Freeze detection.** A freeze is either of these:
  - keyframe_requests growing more than 2/s for at least 5 s;
  - two gestures in a row with no screen change within 8 s.

  At the first detection (then at most once a minute) the driver saves `freeze-NN-*/`:
  the hostd tail, the phone's library log tail (`CMUX_MOBILE_LOG`), the os_log stream
  tail plus `log show --last 3m`, a screenshot, and `summary.json`.

## Rebuild for a SHA

Phone, on mini-cmux8s (`~/brfreeze/src` is a worktree of `~/cmux`; this builds the
TestFlight simulator app into `~/brfreeze/app-<sha12>/CmuxMobileApp.app`):

```bash
ssh mini-cmux8s-mac-mini 'cd ~/brfreeze/src && git fetch -q origin <branch> && ~/brfreeze/tf-build.sh <sha> > ~/brfreeze/logs/tf-build-<sha>.out 2>&1; tail -3 ~/brfreeze/logs/tf-build-<sha>.out'
```

Mac, from a cmux checkout on the laptop (submit only; the fleet builds), then install on
mini-cmux11s:

```bash
~/.local/bin/cmux-ci build cmux --ref <sha> --tag brfz-<sha8> --production --priority -10 \
  --workspace task:cmux-next-ios-browser-freeze-rig --reason "browser freeze rig Mac"
~/.local/bin/cmux-ci wait <job>            # again on a timeout; never resubmit
~/.local/bin/cmux-ci artifact <job> --out /tmp/brfz-mac-<sha8>.zip   # or the URL the wait prints
scp /tmp/brfz-mac-<sha8>.zip mini-cmux11s-mac-mini:~/brfreeze-rig/
ssh mini-cmux11s-mac-mini 'cd ~/brfreeze-rig && python3 rig.py quit; rm -rf src/*.app && ditto -x -k brfz-mac-<sha8>.zip src/ && ls src'
ssh mini-cmux11s-mac-mini 'cd ~/brfreeze-rig && MULTIMAC_PHONE=cmux-brfz LINKREL_CREDS=~/.secrets/brfz-prod.creds python3 rig.py prepare && CMUX_MOBILE_E2E_ALLOW_OTHER_RIGS=1 MULTIMAC_PHONE=cmux-brfz LINKREL_HOSTD_LOG="info,cmux_mobile_link=debug,cmux_mobile_host=debug" python3 rig.py launch'
```

The phone's Mac-side code (hostd, browser host) only matters through the wire. A phone-only
fix can be rerun against the same rig Mac.

## Rerun each configuration

From the laptop (`V` is the verify folder on mini-cmux8s; copy this folder there first):

```bash
V=/Users/cmux/brfreeze/src/cmux-next-ios/verify
tar -C <worktree>/cmux-next-ios/verify -c browser-freeze | ssh mini-cmux8s-mac-mini "tar -x -C $V"
APP=/Users/cmux/brfreeze/app-<sha12>/CmuxMobileApp.app
RIG=mini-cmux11s-mac-mini:~/brfreeze-rig:brfz-term
COMMON="--app $APP --sim cmux-brfz --rig $RIG --creds ~/.secrets/brfz-prod.creds --reuse --install"
cd <worktree>/cmux-next-ios/verify/browser-freeze
python3 -u relay.py mini-cmux8s-mac-mini $V -- $COMMON --config default --out ~/brfreeze/runs/<sha8>-default
python3 -u relay.py mini-cmux8s-mac-mini $V -- $COMMON --config default --bg 20 --out ~/brfreeze/runs/<sha8>-default-bg
python3 -u relay.py mini-cmux8s-mac-mini $V -- $COMMON --config wgonly --out ~/brfreeze/runs/<sha8>-wgonly
python3 -u relay.py mini-cmux8s-mac-mini $V -- $COMMON --config relay --out ~/brfreeze/runs/<sha8>-relay
python3 -u relay.py mini-cmux8s-mac-mini $V -- $COMMON --config loss --drop-permille 40 --out ~/brfreeze/runs/<sha8>-loss
```

Each run writes `run.log`, `actions.jsonl`, `results.json` (per-minute frames, fps,
keyframe requests, input round trips, freezes, host events), `hostd-live.log`,
`oslog-stream.log`, `phone-stderr.log.*`, `shots/` and any `freeze-*/` folders.
`python3 summarize.py RUN_DIR` (on mini-cmux8s) prints the per-minute table.
`--prepare-phone` (without `--rig`) recreates the signed-in simulator from scratch.
