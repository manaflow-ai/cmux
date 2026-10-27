// CmuxNextActions' AppKit side (the registry's menus, the main menu bar, the shortcut recorder,
// NSEvent as an ActionInputEvent) lives here so CmuxNextActions' registry names no AppKit type
// (plans/cmux-next/chrome-parity/p15-oracle.md section H, task 128). A module that imports
// CmuxNextActionsAppKit keeps seeing all of CmuxNextActions, as CmuxNextBrowser re-exports
// CmuxNextBrowserCore: an AppKit file that builds menus imports this module where it imported Actions.
@_exported public import CmuxNextActions
