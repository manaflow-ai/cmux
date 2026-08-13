# Terminal Scroll Lab verification

Verified source: `feat-ios-terminal-scroll-lab` working tree after the fixed-chrome regression test

Ghostty: `11aa609d75dec882ef2f83171e2cbe887aeddbc5` (1.3.2 HEAD)

Remote host: `cmux-aws-m4pro`

Isolated simulator: `TerminalScrollLab-iscrol-33144` (`36FD3FB5-A4C4-4639-B425-8FFAC914D70D`), deleted after verification.

## Automated verification

Four native scroll-state model tests passed. Both interaction tests passed:

- `testBottomEdgeOverscrollReturnsToRest`
- `testFastDragUsesContinuousNativeDeceleration`

The bottom-edge test settled at `10629.3 / 10629.4 pt` with `0.0 pt` presentation translation. The fling test observed UIKit deceleration and asserted that Ghostty's presented viewport row equaled the rounded UIScrollView target row. Both interaction tests also assert that fixed terminal chrome remains stationary.

## Video evidence

Reported recording: `/Users/abdulazizalbahar/Downloads/ScreenRecording_08-08-2026 19-55-07_1.MP4`

Reported SHA-256: `027134813116438efb331db3b57cb6190b9cf43cfe344d3375e58a606de6abc8`

Corrected recording: `/tmp/scroll-lab-after-bounds.mov`

Corrected SHA-256: `23f1d352b416b68d326850db6baa14667f664d8c6d819539162e9f77278f5b02`

The reported recording showed the entire terminal host shifting, including its accessory toolbar. Fractional transforms also placed colored glyphs between physical pixels. The corrected bounce slice contains 193 frames from 158.0 to 167.6 seconds at 20 fps. Inspected frames 75 through 140 show terminal rows following the native drag while the toolbar stays at the same vertical position. Template matching across frames 125 and 135 found the toolbar's best match at exactly 0 px vertical displacement.

The fix keeps UIKit chrome stationary and moves only Ghostty's IOSurface contents. One renderer geometry path now owns both layout and the physical-pixel-aligned fractional offset, so layout cannot erase or duplicate scroll motion. Ghostty's tokened presentation callback rebases the fractional position only after the requested absolute row reaches the renderer.

Computer Use verified the static standalone-app render. Desktop pointer drags did not map to simulator touch events, so the recorded gestures were injected through XCUITest on the isolated simulator.

## Device handoff

The standalone app was signed with the Manaflow development profile, installed on Aziz (`4A52829D-6427-599F-A166-4058881D2DF4`), and launched with bundle identifier `ai.manaflow.TerminalScrollLab`.
