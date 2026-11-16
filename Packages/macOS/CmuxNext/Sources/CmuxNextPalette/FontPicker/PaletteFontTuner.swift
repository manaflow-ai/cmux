import CmuxNextDesign
import Foundation
public import Observation

/// The font picker's state: which surface it sets a font for (``PaletteFontTarget``), the family the
/// highlight is on, and the size and line height the sliders hold. Every change previews the whole
/// set live, family, size and line height together, in the target itself (the terminal, the chat, the
/// Markdown viewer) and in the sample; Return writes the set in one write; leaving restores what was
/// there. Pure state, no AppKit: ``PaletteFontTunerView`` draws it and the palette's keys drive it.
@MainActor
@Observable
public final class PaletteFontTuner {
    public private(set) var targets: [PaletteFontTarget]
    public private(set) var targetIndex: Int
    /// The family option the highlight is on (`PaletteSettingOption.id`), nil before the list shows.
    public private(set) var highlightedOption: String?
    /// The size slider's value; nil when the target has no size setting.
    public private(set) var size: Double?
    /// The line height slider's value; nil when the target has no line height setting.
    public private(set) var lineHeight: Double?
    /// How the picker lays out (the gallery's variants, ``PaletteFontPickerStyle``).
    public let style: PaletteFontPickerStyle
    @ObservationIgnored private let source: any PaletteSettingsSource
    /// The edits the target shows now, so a step that changes nothing previews nothing.
    @ObservationIgnored private var previewed: [PaletteSettingEdit] = []

    /// The target the picker opened on last, kept by the page's provider for the next open.
    @ObservationIgnored private let memory: PaletteFontTargetMemory?

    public init?(rows: [PaletteSettingRow], source: any PaletteSettingsSource, style: PaletteFontPickerStyle? = nil,
                 targetID: String? = nil, memory: PaletteFontTargetMemory? = nil) {
        let targets = PaletteFontTargets.targets(from: rows)
        guard !targets.isEmpty else { return nil }
        self.targets = targets
        self.source = source
        self.style = style ?? PaletteTunables.fontPickerStyle.value
        self.memory = memory
        let wanted = targetID ?? memory?.targetID
        targetIndex = targets.firstIndex { $0.id == wanted } ?? 0
        resetValues()
    }

    public var target: PaletteFontTarget { targets[targetIndex] }

    /// The current family option of the target (what is written now).
    public var currentOption: PaletteSettingOption? { target.familyOptions.first(where: \.isCurrent) }

    /// The family the sample draws in: the highlighted one, else the current one (nil: the
    /// default face, drawn in the body font or the system monospaced face).
    public var sampleFamily: String? {
        let options = target.familyOptions
        let id = highlightedOption ?? currentOption?.id
        return options.first { $0.id == id }?.fontFamily
    }

    /// The highlighted family's title ("Menlo", "Ghostty").
    public var sampleTitle: String {
        let options = target.familyOptions
        let id = highlightedOption ?? currentOption?.id
        return options.first { $0.id == id }?.title ?? target.family.value
    }

    // MARK: Changes

    /// Switches to the target at `index` (wrapping): the old target's preview ends, the new one starts
    /// from its stored values. False when the index is the current one.
    @discardableResult
    public func selectTarget(_ index: Int) -> Bool {
        let wrapped = ((index % targets.count) + targets.count) % targets.count
        guard wrapped != targetIndex else { return false }
        endPreview()
        targetIndex = wrapped
        memory?.targetID = target.id
        resetValues()
        return true
    }

    public func highlight(option: String?) {
        guard option != highlightedOption else { return }
        highlightedOption = option
        preview()
    }

    public func setSize(_ value: Double) {
        guard let number = target.size?.number else { return }
        let snapped = number.snapped(value)
        guard snapped != size else { return }
        size = snapped
        preview()
    }

    public func setLineHeight(_ value: Double) {
        guard let number = target.lineHeight?.number else { return }
        let snapped = number.snapped(value)
        guard snapped != lineHeight else { return }
        lineHeight = snapped
        preview()
    }

    /// One step of the size (Cmd-= and Cmd--).
    public func stepSize(_ steps: Int) {
        guard let number = target.size?.number, let size else { return }
        setSize(size + Double(steps) * number.step)
    }

    /// One step of the line height (Option-Cmd-= and Option-Cmd--): a line height's step is fine
    /// (0.05), so a key moves by a tenth.
    public func stepLineHeight(_ steps: Int) {
        guard let number = target.lineHeight?.number, let lineHeight else { return }
        setLineHeight(lineHeight + Double(steps) * max(number.step, 0.1))
    }

    /// The edits the picker holds that differ from the stored values: the family, the size, the
    /// line height.
    public var edits: [PaletteSettingEdit] {
        var edits: [PaletteSettingEdit] = []
        if let option = highlightedOption, option != currentOption?.id {
            edits.append(PaletteSettingEdit(row: target.family.id, option: option))
        }
        if let row = target.size, let number = row.number, let size, size != number.value {
            edits.append(PaletteSettingEdit(row: row.id, number: size))
        }
        if let row = target.lineHeight, let number = row.number, let lineHeight, lineHeight != number.value {
            edits.append(PaletteSettingEdit(row: row.id, number: lineHeight))
        }
        return edits
    }

    /// Return on a family row: writes that family with the sliders' values, in one write.
    public func commit(option: String) {
        highlightedOption = option
        let edits = edits
        previewed = []
        memory?.targetID = target.id
        if edits.isEmpty { source.endPreview(row: target.family.id) } else { source.commitEdits(edits) }
    }

    /// Leaving without Return: every surface goes back to what it showed.
    public func cancel() {
        endPreview()
    }

    // MARK: Private

    private func preview() {
        let edits = edits
        guard edits != previewed else { return }
        previewed = edits
        if edits.isEmpty { source.endPreview(row: target.family.id) } else { source.previewEdits(edits) }
    }

    private func endPreview() {
        guard !previewed.isEmpty else { return }
        previewed = []
        source.endPreview(row: target.family.id)
    }

    private func resetValues() {
        highlightedOption = currentOption?.id
        size = target.size?.number?.value
        lineHeight = target.lineHeight?.number?.value
        previewed = []
    }
}

/// The font picker's last target (``PaletteFontTarget/id``), owned by the provider that opens the
/// picker, so Change Font… reopens on the surface it was left on.
@MainActor
public final class PaletteFontTargetMemory {
    public var targetID: String?
    public init() {}
}
