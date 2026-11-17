public import CmuxNextDesign
import CmuxNextSettings
import CmuxNextActions
import CmuxNextWakeups
import Foundation
public import Observation

/// The Density Playground's state (Lawrence 2026-11-17: "make a density playground cmd shift p thing so i can fine
/// tune every aspect of density, in terms of vertical and horizontal tabs, and also create new densities").
///
/// It edits one density at a time, the one chrome draws in: every change sets `design.densityTokens`, so the real
/// sidebar, tabs and toolbar redraw as a slider moves. A built-in is never changed: the first edit of one makes a
/// custom copy ("Compact Custom") and edits that. Custom densities save to `appearance.customDensities` (``persist``)
/// a moment after the last change, so the Settings density picker and the palette list them and a restart keeps them.
///
/// ```swift
/// let model = DensityPlaygroundModel(entries: DensityTokenCatalog.entries(), design: .shared) { list, active in … }
/// model.set(DensityTokenCatalog.entry("sidebarRowGap")!, to: 4)   // copies the built-in in use, then sets it
/// ```
@MainActor @Observable
public final class DensityPlaygroundModel {
    /// Every tunable value, in order.
    public let entries: [DensityTokenCatalog.Entry]
    /// The density being edited: the one chrome draws in.
    public private(set) var draft: DensityTokens
    /// The custom densities as the playground has them (saved or about to be).
    public private(set) var customs: [DensityTokens]
    /// Whether the draft has edits not yet written to cmux.json.
    public private(set) var hasUnsavedChanges = false
    /// The last import's failure, shown under the header until the next action.
    public var notice: String?

    @ObservationIgnored private let design: DesignSettings
    @ObservationIgnored private let persist: @MainActor (_ customs: [DensityTokens], _ active: DensityTokens) -> Void
    @ObservationIgnored private let saveTimer = DemandTimer(owner: "densityPlayground.save")
    /// How long after the last change the playground writes cmux.json.
    @ObservationIgnored public var saveDelay: Duration = .milliseconds(600)

    /// - Parameters:
    ///   - entries: The values to list (``DensityTokenCatalog/entries(fallbacks:)``).
    ///   - design: The app's design settings (`DesignSettings.shared`).
    ///   - persist: Writes the custom densities and the density in use to cmux.json.
    public init(entries: [DensityTokenCatalog.Entry], design: DesignSettings,
                persist: @escaping @MainActor (_ customs: [DensityTokens], _ active: DensityTokens) -> Void) {
        self.entries = entries
        self.design = design
        self.persist = persist
        draft = design.densityTokens
        customs = design.customDensities
    }

    /// Picks up the app's density and list again (the window reopening after a Settings change).
    public func refresh() {
        guard !hasUnsavedChanges else { return }
        draft = design.densityTokens
        customs = design.customDensities
    }

    // MARK: The density list

    /// Every density to pick: the built-ins, then the custom ones.
    public var densities: [DensityTokens] { DensityPreset.allCases.map(\.tokens) + customs }

    /// The built-in the draft resets to.
    public var base: DensityTokens { DensityTokenCatalog.base(of: draft) }

    /// Whether the draft is a built-in (its first edit makes a copy).
    public var isBuiltIn: Bool { draft.isBuiltIn }

    /// The name the picker shows for `density`.
    public func name(_ density: DensityTokens) -> String { DensityNames().name(density) }

    /// Switches chrome to the density `id` (saving the draft first).
    public func select(id: String) {
        guard id != draft.id, let density = densities.first(where: { $0.id == id }) else { return }
        flush()
        draft = density
        notice = nil
        applyNow()
        persist(customs, draft)
    }

    /// A new custom density made from the draft, named `name` (default: "<draft> Custom"), selected.
    @discardableResult
    public func duplicate(name: String? = nil) -> DensityTokens {
        flush()
        let made = CustomDensitiesSetting.duplicate(draft, name: uniqueName(name ?? copyName(of: draft)), existing: customs)
        customs.append(made)
        draft = made
        notice = nil
        applyNow()
        persist(customs, draft)
        return made
    }

    /// Renames the draft (a custom density; a built-in is copied under the new name).
    public func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // The field shows ``name(_:)`` (a built-in's display name): leaving it as shown changes nothing.
        guard !trimmed.isEmpty, trimmed != draft.name, trimmed != name(draft) else { return }
        if draft.isBuiltIn {
            duplicate(name: trimmed)
            return
        }
        draft.name = String(trimmed.prefix(64))
        replaceInList()
        scheduleSave()
    }

    /// Deletes the draft (a custom density) and switches to the built-in it was made from.
    public func deleteDraft() {
        guard !draft.isBuiltIn else { return }
        saveTimer.cancel()
        hasUnsavedChanges = false
        customs.removeAll { $0.id == draft.id }
        draft = DensityTokenCatalog.base(of: draft)
        notice = nil
        applyNow()
        persist(customs, draft)
    }

    // MARK: Values

    /// The value `entry` has in the draft (its own, else what chrome derives).
    public func value(_ entry: DensityTokenCatalog.Entry) -> Double? { Self.value(entry, in: draft) }

    /// The value `entry` has in the base.
    public func baseValue(_ entry: DensityTokenCatalog.Entry) -> Double? { Self.value(entry, in: base) }

    /// The value `entry` has at `density`: its own when set, else what chrome derives for it there (`entry.fallback`
    /// read with `density` scoped), else the token of the built-in it was made from.
    public static func value(_ entry: DensityTokenCatalog.Entry, in density: DensityTokens) -> Double? {
        DensityTokenCatalog.value(entry, in: density) { fallback in
            DensityTokens.$scoped.withValueInTask(density) { fallback() }
        }
    }

    /// Whether `entry` differs from the base.
    public func isChanged(_ entry: DensityTokenCatalog.Entry) -> Bool { DensityTokenCatalog.differs(entry, draft, from: base) }

    /// How many values differ from the base.
    public var changedCount: Int { entries.count(where: isChanged) }

    /// Sets `entry`, live; a built-in draft is copied first.
    public func set(_ entry: DensityTokenCatalog.Entry, to value: Double) {
        copyIfBuiltIn()
        let next = DensityTokenCatalog.setting(entry, to: value, in: draft)
        guard next != draft else { return }
        draft = next
        notice = nil
        edited()
    }

    /// Puts `entry` back at the base's value.
    public func reset(_ entry: DensityTokenCatalog.Entry) {
        guard !draft.isBuiltIn else { return }
        draft = DensityTokenCatalog.resetting(entry, in: draft, to: base)
        edited()
    }

    /// Puts every value back at the base's.
    public func resetAll() {
        guard !draft.isBuiltIn else { return }
        draft = DensityTokenCatalog.resettingAll(draft, to: base)
        edited()
    }

    // MARK: Export and import

    /// The draft as `appearance.customDensities` JSON (what Import and the Settings density card read).
    public var exportJSON: String { CustomDensitiesSetting.json(draft).prettyText() }

    /// The draft's values as a Swift dictionary literal, to paste into a built-in (`DensityPreset`).
    public var exportSwift: String {
        var lines = ["// \(draft.name): level \(Self.format(draft.level)), spacing \(Self.format(draft.spacing))"
            + (draft.fontSize.map { ", fontSize \(Self.format($0))" } ?? "")]
        lines.append("[")
        for key in draft.tokens.keys.sorted() {
            lines.append("    \"\(key)\": \(Self.format(draft.tokens[key] ?? 0, digits: 3)),")
        }
        lines.append("]")
        return lines.joined(separator: "\n")
    }

    /// Adds the densities in `text` (one density object or a list of them, as Export writes) and selects the first.
    /// - Returns: How many it added; 0 with ``notice`` set when `text` holds none.
    @discardableResult
    public func importJSON(_ text: String) -> Int {
        guard let root = try? JSONC.parse(text) else {
            notice = DensityPlaygroundStrings.importFailed
            return 0
        }
        let items: [JSONValue] = if case .array(let list) = root { list } else { [root] }
        var added: [DensityTokens] = []
        for item in items {
            guard var density = CustomDensitiesSetting.density(from: item) else { continue }
            // A name or id already in use gets a fresh one, so an import never replaces a density.
            density.name = uniqueName(density.name, extra: added)
            if density.isBuiltIn || (customs + added).contains(where: { $0.id == density.id }) {
                density.id = CustomDensitiesSetting.uniqueID(for: density.name, existing: customs + added)
            }
            added.append(density)
        }
        guard let first = added.first else {
            notice = DensityPlaygroundStrings.importFailed
            return 0
        }
        flush()
        customs += added
        draft = first
        notice = nil
        applyNow()
        persist(customs, draft)
        return added.count
    }

    // MARK: Saving and applying

    /// Writes pending edits now (the window closing, another density picked).
    public func flush() {
        saveTimer.cancel()
        guard hasUnsavedChanges else { return }
        hasUnsavedChanges = false
        persist(customs, draft)
    }

    private func edited() {
        replaceInList()
        // At once: a density is one struct, and the views redraw once per frame however many ticks it holds.
        applyNow()
        scheduleSave()
    }

    private func replaceInList() {
        if let index = customs.firstIndex(where: { $0.id == draft.id }) { customs[index] = draft }
    }

    private func copyIfBuiltIn() {
        guard draft.isBuiltIn else { return }
        let made = CustomDensitiesSetting.duplicate(draft, name: uniqueName(copyName(of: draft)), existing: customs)
        customs.append(made)
        draft = made
    }

    private func applyNow() {
        guard design.densityTokens != draft else { return }
        design.densityTokens = draft
    }

    private func scheduleSave() {
        hasUnsavedChanges = true
        saveTimer.schedule(after: saveDelay) { @MainActor [weak self] in self?.flush() }
    }

    private func copyName(of density: DensityTokens) -> String {
        DensityPlaygroundStrings.copyName(name(density))
    }

    private func uniqueName(_ name: String, extra: [DensityTokens] = []) -> String {
        let taken = Set((densities + extra).map { self.name($0).lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var index = 2
        while taken.contains("\(name) \(index)".lowercased()) { index += 1 }
        return "\(name) \(index)"
    }

    /// `value` with at most `digits` decimals and no trailing zeros (the fields show 2; Copy as Swift keeps 3).
    static func format(_ value: Double, digits: Int = 2) -> String {
        let scale = pow(10, Double(digits))
        let rounded = (value * scale).rounded() / scale
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
    }
}
