// CmuxNextCompat's AppKit and QuartzCore helpers live here so CmuxNextCompat sheds them on its way to
// building on Linux (plans/cmux-next/chrome-parity/p15-oracle.md section H, task 119).
// A module that imports CmuxNextCompatAppKit keeps seeing all of CmuxNextCompat, the way CmuxNextBrowser
// re-exports CmuxNextBrowserCore: an AppKit file imports this module where it imported Compat.
@_exported public import CmuxNextCompat
