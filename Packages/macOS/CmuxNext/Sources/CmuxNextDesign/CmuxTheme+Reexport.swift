public import CmuxTheme

// The theme values live in the shared CmuxTheme package so iOS derives the
// same tokens. These names keep every CmuxNext module that imports
// CmuxNextDesign compiling unchanged; a module's own declarations shadow the
// ones it imports, so a file importing both still resolves to one type.

/// An sRGB color with alpha; see ``CmuxTheme/ThemeRGB``.
public typealias ThemeRGB = CmuxTheme.ThemeRGB
/// The user's terminal theme colors; see ``CmuxTheme/ThemeInput``.
public typealias ThemeInput = CmuxTheme.ThemeInput
/// The chrome colors derived from a terminal theme; see ``CmuxTheme/ThemeTokens``.
public typealias ThemeTokens = CmuxTheme.ThemeTokens
/// The app theme's contract tokens from a terminal palette; see ``CmuxTheme/AppTheme``.
public typealias AppTheme = CmuxTheme.AppTheme
/// Where the chrome's accent comes from; see ``CmuxTheme/ThemeAccent``.
public typealias ThemeAccent = CmuxTheme.ThemeAccent
/// One Ghostty theme file's colors; see ``CmuxTheme/ThemeFileColors``.
public typealias ThemeFileColors = CmuxTheme.ThemeFileColors
/// Where a color transition blends; see ``CmuxTheme/ThemeColorSpace``.
public typealias ThemeColorSpace = CmuxTheme.ThemeColorSpace
