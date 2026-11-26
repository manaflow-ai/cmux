# Screen parity: golden screenshots

`shots.sh simctl OUT APP` launches the NEXT iOS app on each fixture screen in `screens.tsv` (the list rig's
`CMUX_MOBILE_LIST_SCREEN` fixtures with mock auth, plus the signed-out screen), in light and dark, with the status
bar at 9:41, and saves one settled screenshot per screen with a `meta.json`.

`.github/workflows/ios-sim-linux-build.yml` runs it on an iPhone 17 Pro simulator after the build when dispatched
with `screens: true` or pushed on a `lane/ios-sim-linux-screen-parity*` branch, and uploads `ios-sim-mac-shots`
(the screenshots and these files). Those are the reference the simulator runner on Linux is compared with.

Add a screen by adding a row: `name<TAB>light|dark<TAB>NAME=VALUE ...` (environment for the launch).
