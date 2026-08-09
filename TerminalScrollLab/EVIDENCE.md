# Terminal Scroll Lab verification

Verified commit: `2d932da7fd`

Ghostty: `11aa609d75dec882ef2f83171e2cbe887aeddbc5` (1.3.2 HEAD)

Remote host: `aws-m4pro-5`

Isolated simulator: `TerminalScrollLab-iscrol-88623` (`DE67ABEB-C970-4B92-B459-40A59F43488E`), deleted after verification.

## Automated verification

Four native scroll-state model tests passed. Both interaction tests passed:

- `testBottomEdgeOverscrollReturnsToRest`
- `testFastDragUsesContinuousNativeDeceleration`

The bottom-edge test settled at `10629.3 / 10629.4 pt` with `0.0 pt` presentation translation. The fling test observed UIKit deceleration and asserted that Ghostty's rendered viewport row equaled the rounded UIScrollView target row.

## Video evidence

Recording: `cmux-assets/feat-ios-terminal-scroll-lab/final-absolute/native-scroll-tests.mov`

SHA-256: `df76d7b38d8135c1825697361d317dd31ee320137758a0e4332874c03588af41`

The bounce slice contains 170 frames from 65.5 to 74.0 seconds at 20 fps. Inspected frames 90, 110, 120, 130, and 140 show bottom overscroll reaching 185.3 pt, native deceleration, and return to rest at zero translation. The fixed header remains stationary and the Ghostty surface remains clipped below it.

The fling slice contains 133 frames from 73.5 to 80.2 seconds at 20 fps. Inspected frames 70, 80, 90, 100, and 110 through 120 show continuous pixel movement slowing to rest. The final rendered viewport row is 685, equal to the rounded target row 685.

The first recording exposed a mismatch between UIScrollView position and Ghostty content because the local mouse-wheel path applied independent acceleration. The fix uses Ghostty's revision-checked absolute viewport API, leaving UIScrollView as the sole physics authority. Fractional presentation translation bridges the interval between integer terminal rows.

Computer Use verified the static standalone-app render. Desktop pointer drags did not map to simulator touch events, so the recorded gestures were injected through XCUITest on the isolated simulator.

## Device handoff

The standalone app was signed with the Manaflow development profile, installed on Aziz (`4A52829D-6427-599F-A166-4058881D2DF4`), and launched with bundle identifier `ai.manaflow.TerminalScrollLab`.
