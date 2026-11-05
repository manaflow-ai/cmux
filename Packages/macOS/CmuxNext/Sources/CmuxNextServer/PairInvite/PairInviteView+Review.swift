import AppKit
import CmuxNextDesign

/// The arrived machine on the Pair Another Machine card: Add Server's facts, the four words, the
/// name and the Chief option, then the note that only a click confirms.
extension PairInviteView {
    // MARK: - The arrived machine (Add Server's facts and words)

    func buildReview(_ candidate: PairingCandidate, width: CGFloat) {
        header(PairInviteStrings.arrived, width: width)
        stack.addArrangedSubview(facts(candidate, width: width))
        stack.addArrangedSubview(label(ServerStrings.wordsQuestion, font: Typography.bodyEmphasized, color: Palette.textPrimary, width: width))
        stack.addArrangedSubview(words(candidate.words, width: width))
        stack.addArrangedSubview(label(ServerStrings.wordsWarning, font: Typography.caption, color: Palette.textTertiary, width: width))
        if nameFieldCode != candidate.code {
            nameFieldCode = candidate.code
            nameField.stringValue = candidate.name
        }
        nameField.placeholderString = candidate.name
        let nameRow = NSStackView()
        nameRow.orientation = .horizontal
        nameRow.alignment = .firstBaseline
        nameRow.spacing = Metrics.space3
        nameRow.addArrangedSubview(label(ServerStrings.name, font: Typography.body, color: Palette.textSecondary, width: nil))
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameRow.addArrangedSubview(nameField)
        nameRow.translatesAutoresizingMaskIntoConstraints = false
        nameRow.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(nameRow)
        let chief = NSButton(checkboxWithTitle: ServerStrings.runChief, target: self, action: #selector(runChiefChanged(_:)))
        chief.state = model.approver.approval.runChief ? .on : .off
        chief.font = Typography.body
        chief.setAccessibilityIdentifier("cmux.pairInvite.runChief")
        stack.addArrangedSubview(chief)
        stack.addArrangedSubview(label(PairInviteStrings.confirmNote, font: Typography.caption, color: Palette.textTertiary, width: width))
    }

    private func facts(_ candidate: PairingCandidate, width: CGFloat) -> NSView {
        var parts = [candidate.os, candidate.version].filter { !$0.isEmpty }
        if let region = candidate.region {
            parts.append(Locale.current.localizedString(forRegionCode: region) ?? region)
        }
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.space1
        column.edgeInsets = NSEdgeInsets(top: Metrics.space3, left: Metrics.space3, bottom: Metrics.space3, right: Metrics.space3)
        column.wantsLayer = true
        column.layer?.cornerRadius = 8
        column.layer?.backgroundColor = Palette.textPrimary.withAlphaComponent(0.06).cgColor
        column.addArrangedSubview(label(candidate.name, font: Typography.bodyEmphasized, color: Palette.textPrimary, width: width - 2 * Metrics.space3))
        column.addArrangedSubview(label(parts.joined(separator: " · "), font: Typography.caption, color: Palette.textSecondary,
                                        width: width - 2 * Metrics.space3))
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: width).isActive = true
        column.setAccessibilityIdentifier("cmux.pairInvite.facts")
        return column
    }

    /// The four fingerprint words, two by two, numbered (Add Server's grid).
    private func words(_ words: [String], width: CGFloat) -> NSView {
        let cells = words.enumerated().map { index, word -> NSView in
            let cell = NSStackView()
            cell.spacing = Metrics.space2
            cell.alignment = .firstBaseline
            cell.edgeInsets = NSEdgeInsets(top: Metrics.space2, left: Metrics.space3, bottom: Metrics.space2, right: Metrics.space3)
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 8
            cell.layer?.backgroundColor = Palette.textPrimary.withAlphaComponent(0.06).cgColor
            cell.addArrangedSubview(label("\(index + 1)", font: Typography.caption, color: Palette.textTertiary, width: nil))
            cell.addArrangedSubview(label(word, font: Typography.system(size: TypeScale.field, weight: TypeScale.emphasis), color: Palette.textPrimary, width: nil))
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            cell.addArrangedSubview(spacer)
            cell.translatesAutoresizingMaskIntoConstraints = false
            cell.widthAnchor.constraint(equalToConstant: (width - Metrics.space2) / 2).isActive = true
            return cell
        }
        let rows = stride(from: 0, to: cells.count, by: 2).map { Array(cells[$0..<min($0 + 2, cells.count)]) }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = Metrics.space2
        grid.columnSpacing = Metrics.space2
        grid.setAccessibilityIdentifier("cmux.pairInvite.words")
        grid.setAccessibilityElement(true)
        grid.setAccessibilityLabel(words.joined(separator: ", "))
        return grid
    }

    @objc private func runChiefChanged(_ sender: NSButton) {
        model.approver.approval.runChief = sender.state == .on
    }
}
