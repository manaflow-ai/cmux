public import AppKit
import CmuxNextDesign
import Observation

/// The looks of the "Any machine: one line" way. The gallery (AddDeviceShotsTests) draws each;
/// the app uses ``card``.
public nonisolated enum JoinLineLayout: String, CaseIterable, Sendable {
    /// The help, the line in the monospaced box with its countdown under it, and the note.
    case card
    /// The same parts as three numbered steps: name it, copy the line, paste it there.
    case steps
    /// No help text: the line on one row, its countdown inside the box.
    case compact
}

/// The "Any machine: one line" way's body. It reads the phase, the copy and the checks; the
/// countdown is its own label (``JoinLineCountdownLabel``), so a tick redraws one label and never
/// the Name field the person may be typing in.
extension AddDeviceView: NSTextFieldDelegate {
    func buildJoinLine(_ width: CGFloat) {
        guard let join = model.joinLine else { return }
        let compact = joinLineLayout == .compact
        // The help is for making and pasting the line; after the flip or the expiry it is noise.
        let helps: Bool = switch join.phase {
        case .idle, .minting, .showing: true
        case .joined, .expired, .failed: false
        }
        if helps, !compact, joinLineLayout != .steps {
            stack.addArrangedSubview(label(AddDeviceStrings.joinLineHelp, font: Typography.body, color: Palette.textSecondary, width: width))
        }
        switch join.phase {
        case .idle:
            if joinLineLayout == .steps { stack.addArrangedSubview(step(1, AddDeviceStrings.joinLineName, width: width)) }
            stack.addArrangedSubview(nameField(join, width: width))
        case .minting:
            stack.addArrangedSubview(waitingRow(AddDeviceStrings.joinLineMinting, width: width))
        case let .showing(line):
            if joinLineLayout == .steps { stack.addArrangedSubview(step(1, AddDeviceButtonTitle.copy, width: width)) }
            stack.addArrangedSubview(lineBox(line.line, join: join, width: width))
            if !compact {
                let row = NSStackView()
                row.spacing = Metrics.space2
                row.addArrangedSubview(JoinLineCountdownLabel(model: join))
                row.addArrangedSubview(label("· " + AddDeviceStrings.joinLineOnce, font: Typography.caption, color: Palette.textTertiary, width: nil))
                stack.addArrangedSubview(row)
            }
            if joinLineLayout == .steps { stack.addArrangedSubview(step(2, AddDeviceStrings.joinLinePaste, width: width)) }
            stack.addArrangedSubview(waitingRow(AddDeviceStrings.joinLineWaiting, width: width))
        case let .joined(_, machine):
            stack.addArrangedSubview(label(AddDeviceStrings.joinLineJoined(machine.name), font: Typography.bodyEmphasized,
                                           color: Palette.textPrimary, width: width))
            if join.checks.isEmpty {
                stack.addArrangedSubview(waitingRow(AddDeviceStrings.joinLineChecking, width: width))
            } else {
                for check in join.checks { stack.addArrangedSubview(checkRow(check, width: width)) }
            }
        case .expired:
            stack.addArrangedSubview(label(AddDeviceStrings.joinLineExpired, font: Typography.body, color: Palette.textPrimary, width: width))
        case let .failed(failure):
            stack.addArrangedSubview(label(AddDeviceStrings.joinLineFailed(failure), font: Typography.body, color: Palette.danger, width: width))
        }
        stack.addArrangedSubview(label(AddDeviceStrings.joinLineConsent, font: Typography.caption, color: Palette.textTertiary, width: width))
    }

    private func step(_ number: Int, _ text: String, width: CGFloat) -> NSView {
        label("\(number). \(text)", font: Typography.bodyEmphasized, color: Palette.textPrimary, width: width)
    }

    private func nameField(_ join: MachineJoinLineModel, width: CGFloat) -> NSView {
        let row = NSStackView()
        row.spacing = Metrics.space3
        row.alignment = .firstBaseline
        if joinLineLayout != .steps {
            row.addArrangedSubview(label(AddDeviceStrings.joinLineName, font: Typography.body, color: Palette.textSecondary, width: nil))
        }
        let field = NSTextField(string: join.name)
        field.placeholderString = AddDeviceStrings.joinLineNamePlaceholder
        field.font = Typography.body
        field.delegate = self
        field.setAccessibilityIdentifier("cmux.addDevice.joinLine.name")
        field.setAccessibilityLabel(AddDeviceStrings.joinLineName)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(field)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field.accessibilityIdentifier() == "cmux.addDevice.joinLine.name" else { return }
        model.joinLine?.name = field.stringValue
    }

    /// The line in the same monospaced box as "Set up a new device". Selecting it by hand is
    /// allowed; Copy Line is the concealed copy.
    private func lineBox(_ line: String, join: MachineJoinLineModel, width: CGFloat) -> NSView {
        let compact = joinLineLayout == .compact
        let field = compact ? NSTextField(labelWithString: line) : NSTextField(wrappingLabelWithString: line)
        field.isSelectable = true
        field.focusRingType = .none
        field.font = Typography.system(.monospaced, size: TypeScale.detail)
        field.textColor = Palette.textPrimary
        if compact {
            field.lineBreakMode = .byTruncatingMiddle
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            field.preferredMaxLayoutWidth = width - 2 * Metrics.space3
        }
        field.setAccessibilityIdentifier("cmux.addDevice.joinLine.line")
        let box = NSStackView()
        box.orientation = .horizontal
        box.spacing = Metrics.space2
        box.edgeInsets = NSEdgeInsets(top: Metrics.space3, left: Metrics.space3, bottom: Metrics.space3, right: Metrics.space3)
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = Palette.textPrimary.withAlphaComponent(0.06).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addArrangedSubview(field)
        if compact { box.addArrangedSubview(JoinLineCountdownLabel(model: join)) }
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        return box
    }

    private func waitingRow(_ text: String, width: CGFloat) -> NSView {
        let row = NSStackView()
        row.spacing = Metrics.space2
        row.addArrangedSubview(StatusIndicatorView.spinner())
        row.addArrangedSubview(label(text, font: Typography.body, color: Palette.textSecondary, width: width - 24))
        return row
    }

    private func checkRow(_ check: HostStepResult, width: CGFloat) -> NSView {
        let (mark, color): (String, NSColor) = switch check.state {
        case .ok, .fixed: ("✓", Palette.success)
        case .warn: ("!", Palette.attention)
        case .fail: ("✕", Palette.danger)
        case .skip: ("–", Palette.textTertiary)
        }
        let row = NSStackView()
        row.spacing = Metrics.space2
        row.alignment = .firstBaseline
        row.addArrangedSubview(label(mark, font: Typography.bodyEmphasized, color: color, width: nil))
        let text = [AddMachineStrings.step(check.step), check.state == .fail ? check.fix ?? check.detail : check.detail]
            .filter { !$0.isEmpty }.joined(separator: ": ")
        row.addArrangedSubview(label(text, font: Typography.caption, color: Palette.textSecondary, width: width - 24))
        return row
    }
}

/// The Copy Line title for the steps layout's first step.
private enum AddDeviceButtonTitle {
    static var copy: String { AddDeviceStrings.button(.copyJoinLine, copied: false) }
}

/// "Expires in 9:41", redrawn on each countdown tick, in the attention color under a minute.
@MainActor
final class JoinLineCountdownLabel: NSTextField {
    private let model: MachineJoinLineModel

    init(model: MachineJoinLineModel) {
        self.model = model
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = Typography.system(.monospaced, size: TypeScale.caption)
        setAccessibilityIdentifier("cmux.addDevice.joinLine.countdown")
        draw()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draws the time left and draws again when it changes. The chain ends with the label: a
    /// change after it left the window finds `self` gone.
    private func draw() {
        withObservationTracking {
            let left = model.secondsLeft ?? 0
            stringValue = AddDeviceStrings.joinLineExpires(left)
            textColor = left < 60 ? Palette.attention : Palette.textSecondary
        } onChange: { [weak self] in
            Task { @MainActor in self?.draw() }
        }
    }
}
