import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit
import Network
import CFNetwork
import SQLite3
import CryptoKit
import Darwin
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif


// MARK: - Browser import hint settings
enum BrowserImportHintVariant: String, CaseIterable, Identifiable {
    case inlineStrip
    case floatingCard
    case toolbarChip
    case settingsOnly

    var id: String { rawValue }
}

enum BrowserImportHintBlankTabPlacement: Equatable {
    case hidden
    case inlineStrip
    case floatingCard
    case toolbarChip
}

enum BrowserImportHintSettingsStatus: Equatable {
    case visible
    case hidden
    case settingsOnly
}

struct BrowserImportHintPresentation: Equatable {
    let blankTabPlacement: BrowserImportHintBlankTabPlacement
    let settingsStatus: BrowserImportHintSettingsStatus

    init(
        variant: BrowserImportHintVariant,
        showOnBlankTabs: Bool,
        isDismissed: Bool
    ) {
        if variant == .settingsOnly {
            blankTabPlacement = .hidden
            settingsStatus = .settingsOnly
            return
        }

        if !showOnBlankTabs || isDismissed {
            blankTabPlacement = .hidden
            settingsStatus = .hidden
            return
        }

        switch variant {
        case .inlineStrip:
            blankTabPlacement = .inlineStrip
        case .floatingCard:
            blankTabPlacement = .floatingCard
        case .toolbarChip:
            blankTabPlacement = .toolbarChip
        case .settingsOnly:
            blankTabPlacement = .hidden
        }
        settingsStatus = .visible
    }
}

enum BrowserImportHintSettings {
    static let variantKey = "browserImportHintVariant"
    static let showOnBlankTabsKey = "browserImportHintShowOnBlankTabs"
    static let dismissedKey = "browserImportHintDismissed"
    static let defaultVariant: BrowserImportHintVariant = .toolbarChip
    static let defaultShowOnBlankTabs = true
    static let defaultDismissed = false

    static func variant(for rawValue: String?) -> BrowserImportHintVariant {
        guard let rawValue, let variant = BrowserImportHintVariant(rawValue: rawValue) else {
            return defaultVariant
        }
        return variant
    }

    static func variant(defaults: UserDefaults = .standard) -> BrowserImportHintVariant {
        variant(for: defaults.string(forKey: variantKey))
    }

    static func showOnBlankTabs(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showOnBlankTabsKey) == nil {
            return defaultShowOnBlankTabs
        }
        return defaults.bool(forKey: showOnBlankTabsKey)
    }

    static func isDismissed(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: dismissedKey) == nil {
            return defaultDismissed
        }
        return defaults.bool(forKey: dismissedKey)
    }

    static func presentation(defaults: UserDefaults = .standard) -> BrowserImportHintPresentation {
        BrowserImportHintPresentation(
            variant: variant(defaults: defaults),
            showOnBlankTabs: showOnBlankTabs(defaults: defaults),
            isDismissed: isDismissed(defaults: defaults)
        )
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.set(defaultVariant.rawValue, forKey: variantKey)
        defaults.set(defaultShowOnBlankTabs, forKey: showOnBlankTabsKey)
        defaults.set(defaultDismissed, forKey: dismissedKey)
    }
}

