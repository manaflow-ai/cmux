// CmuxNextWakeups' AppKit and QuartzCore files move here so CmuxNextWakeups itself imports no UI
// framework and builds on Linux (plans/cmux-next/chrome-parity/p15-oracle.md section H, task 125).
// A module that imports CmuxNextWakeupsDisplay keeps seeing all of CmuxNextWakeups, the way
// CmuxNextBrowser re-exports CmuxNextBrowserCore: a file that uses a moved type imports this module
// where it imported Wakeups.
@_exported public import CmuxNextWakeups
