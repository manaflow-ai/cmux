// Every module that imports CmuxNextDesign keeps seeing the values that moved to
// CmuxNextDesignTokens (plans/cmux-next/architecture-refactor-DESIGN.md slice B2) and the
// appearance state that moved to CmuxNextAppearance (DesignSettings, AppearanceSignals, the
// backdrop catalog and selection; p15-oracle-134). A module that needs only those imports
// CmuxNextDesignTokens or CmuxNextAppearance directly.
@_exported public import CmuxNextAppearance
@_exported public import CmuxNextDesignTokens
