public import Foundation
import CmuxSettings

/// Registers browser fallback defaults and writes back canonical values for any
/// stored browser setting whose raw value is legacy or out of range.
///
/// This is the package home for the app target's former
/// `BrowserPanel.normalizeBrowserDefaults(defaults:)`. It is pure with respect to
/// the injected `defaults`, so it is unit-testable against a scratch
/// `UserDefaults(suiteName:)` without touching `UserDefaults.standard`. The app
/// owns the once-per-process bootstrap guard that calls this with
/// `UserDefaults.standard`; this type takes the `UserDefaults` as a parameter and
/// never reaches for `.standard` itself.
///
/// Every key, default, and clamp it touches stays byte-identical to the persisted
/// state the running browser reads, so `@AppStorage(key)` consumers and this
/// normalization agree on the same values.
public struct BrowserDefaultsNormalizer {
    /// Creates a normalizer.
    public init() {}

    /// Registers fallback defaults and writes back canonical values for any stored
    /// browser setting whose raw value is legacy or out of range, against the
    /// injected `defaults`.
    public func normalize(defaults: UserDefaults) {
        let toolbarSpacing = BrowserToolbarAccessorySpacingDebugRepository(defaults: defaults)
        let popoverPadding = BrowserProfilePopoverDebugRepository(defaults: defaults)

        defaults.register(defaults: [
            BrowserSearchSettingsStore.searchEngineKey: BrowserSearchSettingsStore.defaultSearchEngine.rawValue,
            BrowserSearchSettingsStore.customSearchEngineNameKey: BrowserSearchSettingsStore.defaultCustomSearchEngineName,
            BrowserSearchSettingsStore.customSearchEngineURLTemplateKey: BrowserSearchSettingsStore.defaultCustomSearchEngineURLTemplate,
            BrowserSearchSettingsStore.searchSuggestionsEnabledKey: BrowserSearchSettingsStore.defaultSearchSuggestionsEnabled,
            BrowserToolbarAccessorySpacingDebugRepository.key: BrowserToolbarAccessorySpacingDebugRepository.defaultSpacing,
            BrowserProfilePopoverDebugRepository.horizontalPaddingKey: BrowserProfilePopoverDebugRepository.defaultHorizontalPadding,
            BrowserProfilePopoverDebugRepository.verticalPaddingKey: BrowserProfilePopoverDebugRepository.defaultVerticalPadding,
            BrowserThemeMode.modeKey: BrowserThemeMode.defaultMode.rawValue,
        ])

        let resolvedThemeMode = BrowserThemeMode.mode(defaults: defaults)
        let currentThemeRaw = defaults.string(forKey: BrowserThemeMode.modeKey)
            ?? BrowserThemeMode.defaultMode.rawValue
        if currentThemeRaw != resolvedThemeMode.rawValue {
            defaults.set(resolvedThemeMode.rawValue, forKey: BrowserThemeMode.modeKey)
        }

        let hintRepository = BrowserImportHintRepository(defaults: defaults)
        let resolvedHintVariant = hintRepository.variant()
        let currentHintRaw = defaults.string(forKey: BrowserImportHintRepository.variantKey)
            ?? BrowserImportHintRepository.defaultVariant.rawValue
        if currentHintRaw != resolvedHintVariant.rawValue {
            defaults.set(resolvedHintVariant.rawValue, forKey: BrowserImportHintRepository.variantKey)
        }

        let resolvedToolbarSpacing = toolbarSpacing.current()
        let currentToolbarSpacing = (defaults.object(forKey: BrowserToolbarAccessorySpacingDebugRepository.key) as? Int)
            ?? BrowserToolbarAccessorySpacingDebugRepository.defaultSpacing
        if currentToolbarSpacing != resolvedToolbarSpacing {
            defaults.set(resolvedToolbarSpacing, forKey: BrowserToolbarAccessorySpacingDebugRepository.key)
        }

        let resolvedHorizontalPadding = popoverPadding.currentHorizontalPadding()
        let currentHorizontalPadding = (defaults.object(forKey: BrowserProfilePopoverDebugRepository.horizontalPaddingKey) as? NSNumber)?.doubleValue
            ?? BrowserProfilePopoverDebugRepository.defaultHorizontalPadding
        if currentHorizontalPadding != resolvedHorizontalPadding {
            defaults.set(resolvedHorizontalPadding, forKey: BrowserProfilePopoverDebugRepository.horizontalPaddingKey)
        }

        let resolvedVerticalPadding = popoverPadding.currentVerticalPadding()
        let currentVerticalPadding = (defaults.object(forKey: BrowserProfilePopoverDebugRepository.verticalPaddingKey) as? NSNumber)?.doubleValue
            ?? BrowserProfilePopoverDebugRepository.defaultVerticalPadding
        if currentVerticalPadding != resolvedVerticalPadding {
            defaults.set(resolvedVerticalPadding, forKey: BrowserProfilePopoverDebugRepository.verticalPaddingKey)
        }
    }
}
