# Screen parity: golden screenshots

`shots.sh` launches the NEXT iOS app on each fixture screen in `screens.tsv` (the list rig's
`CMUX_MOBILE_LIST_SCREEN` fixtures with mock auth, plus the signed-out screen), in light and dark, with the status
bar at 9:41, and saves one screenshot per screen with a `meta.json`:

- `shots.sh fleet OUT SHA` takes them on a fleet simulator Mac through the fleet's `shots` step
  (`scripts/ci/cmux-next-ios-sim.sh`, which builds the app at SHA), from any host with `cmux-ci`.
- `shots.sh simctl OUT APP` takes them on this Mac's booted simulator, waiting for two identical frames.

`.github/workflows/ios-sim-linux-build.yml` (job `shots-fleet`) runs `fleet` on an iPhone 17 Pro when dispatched
with `screens: true` or pushed on a `lane/ios-sim-linux-screen-parity*` branch, and uploads `ios-sim-mac-shots`
(the screenshots and these files). Those are the reference the simulator runner on Linux is compared with.

Add a screen by adding a pair of rows, `NAME-light` and `NAME-dark`:
`name<TAB>light|dark<TAB>NAME=VALUE ...` (environment for the launch; both rows the same).
