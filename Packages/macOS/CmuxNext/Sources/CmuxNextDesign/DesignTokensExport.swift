// Every module that imports CmuxNextDesign keeps seeing the values that moved to
// CmuxNextDesignTokens (plans/cmux-next/architecture-refactor-DESIGN.md slice B2). A module that
// needs only values imports CmuxNextDesignTokens directly.
@_exported public import CmuxNextDesignTokens
