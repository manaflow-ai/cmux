// The control socket's Darwin-only diagnostics (the main-thread and busy watchdogs, the hang monitor, the
// Mach stack sampler) live here so CmuxNextControl names none of them (plans/cmux-next/chrome-parity/p15-oracle.md
// section H, task 136). A module that imports CmuxNextControlDiagnostics keeps seeing all of CmuxNextControl,
// as CmuxNextBrowser re-exports CmuxNextBrowserCore: a file that wires the watchdog imports this module where
// it imported Control.
@_exported public import CmuxNextControl
