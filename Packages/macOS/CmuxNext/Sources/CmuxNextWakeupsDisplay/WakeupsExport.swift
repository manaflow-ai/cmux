// CmuxNextWakeups' AppKit and QuartzCore files move here, a layer above it, so CmuxNextWakeups can
// build on Linux (plans/cmux-next/chrome-parity/p15-oracle.md section H). Task 125 moved
// ChatOpenTrace and WindowServerInputEvents; Wakeups still imports AppKit, QuartzCore and
// CoreGraphics until the DisplayPlatform and input seams (302, 303) and the remaining moves (304).
// A module that imports CmuxNextWakeupsDisplay keeps seeing all of CmuxNextWakeups, the way
// CmuxNextBrowser re-exports CmuxNextBrowserCore: a file that uses a moved type imports this module
// where it imported Wakeups.
@_exported public import CmuxNextWakeups
