import CmuxNextBrowserImport
import Foundation

/// Text and selection helpers the Import variants share, all derived from
/// `ImportStepModel` (the model stays the only owner of the choice).
@MainActor
enum ImportKit {
    /// "3 of 4 profiles".
    static func countText(_ model: ImportStepModel) -> String {
        ImportVariantStrings.selectedCount(model.profiles.filter { model.isSelected($0) }.count, model.profiles.count)
    }

    /// "Bookmarks, History, and Sign-ins" in offered order, or "Nothing selected".
    static func kindsText(_ model: ImportStepModel) -> String {
        let names = ImportStepModel.offeredKinds.filter { model.kinds.contains($0) }.map { OnboardingStrings.kind($0) }
        return names.isEmpty ? ImportVariantStrings.nothingSelected : ListFormatter.localizedString(byJoining: names)
    }

    /// The calm line shown where the list would be: still looking, or
    /// nothing found. Nil once there is a list.
    static func emptyText(_ model: ImportStepModel) -> String? {
        switch model.phase {
        case .idle: OnboardingStrings.findBrowsersHint
        case .detecting: OnboardingStrings.detecting
        default: model.profiles.isEmpty ? OnboardingStrings.noBrowsers : nil
        }
    }

    /// Progress while importing, a failure, or the Keychain note when sign-ins are on.
    static func noteText(_ model: ImportStepModel) -> String {
        switch model.phase {
        case .importing(let progress): progress.map { OnboardingStrings.importing(OnboardingStrings.profileName($0.profile)) } ?? ""
        case .failed(let message): message
        default: !model.profiles.isEmpty && model.kinds.contains(.cookies) ? OnboardingStrings.keychainNote : ""
        }
    }

    /// Every profile and kind on, or every profile off.
    static func setEverything(_ model: ImportStepModel, on: Bool) {
        for profile in model.profiles where model.isSelected(profile) != on { model.toggle(profile) }
        guard on else { return }
        for kind in ImportStepModel.offeredKinds where !model.kinds.contains(kind) { model.toggle(kind) }
    }

    /// All profiles on and all kinds on (true), none (false), or a mix (nil).
    static func everythingState(_ model: ImportStepModel) -> Bool? {
        let selected = model.profiles.filter { model.isSelected($0) }.count
        if selected == 0 { return false }
        let allKinds = ImportStepModel.offeredKinds.allSatisfy { model.kinds.contains($0) }
        return selected == model.profiles.count && allKinds ? true : nil
    }

    /// Only `profile` on; nil turns every profile on.
    static func selectOnly(_ model: ImportStepModel, _ profile: BrowserSourceProfile?) {
        for candidate in model.profiles {
            let wanted = profile == nil || candidate == profile
            if model.isSelected(candidate) != wanted { model.toggle(candidate) }
        }
    }

    /// Profiles grouped by browser, in detection order.
    static func groups(_ profiles: [BrowserSourceProfile]) -> [(browser: ImportBrowser, profiles: [BrowserSourceProfile])] {
        var order: [ImportBrowser] = []
        var byBrowser: [ImportBrowser: [BrowserSourceProfile]] = [:]
        for profile in profiles {
            if byBrowser[profile.browser] == nil { order.append(profile.browser) }
            byBrowser[profile.browser, default: []].append(profile)
        }
        return order.map { ($0, byBrowser[$0] ?? []) }
    }
}
