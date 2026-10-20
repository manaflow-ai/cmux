import AppKit
import CmuxNextFiles

/// Finder's Rename Items sheet: Replace Text, Add Text or Format, with a live
/// example from the first selected name.
@MainActor
final class BatchRenameSheet: NSObject {
    private let names: [String]
    private let mode = NSPopUpButton()
    private let first = NSTextField(string: "")
    private let second = NSTextField(string: "")
    private let firstLabel = NSTextField(labelWithString: "")
    private let secondLabel = NSTextField(labelWithString: "")
    private let formatStyle = NSPopUpButton()
    private let position = NSPopUpButton()
    private let caseSensitive = NSButton(checkboxWithTitle: FilesStrings.renameCaseSensitive, target: nil, action: nil)
    private let example = NSTextField(labelWithString: "")
    let accessory = NSStackView()

    /// Makes the sheet's controls for `names` (display order).
    init(names: [String]) {
        self.names = names
        super.init()
        mode.addItems(withTitles: [FilesStrings.renameReplace, FilesStrings.renameAdd, FilesStrings.renameFormat])
        formatStyle.addItems(withTitles: [FilesStrings.renameNameIndex, FilesStrings.renameNameCounter, FilesStrings.renameNameDate])
        position.addItems(withTitles: [FilesStrings.renameAfter, FilesStrings.renameBefore])
        caseSensitive.state = .on
        for control in [mode, formatStyle, position, caseSensitive] as [NSControl] {
            control.target = self
            control.action = #selector(changed)
        }
        for field in [first, second] {
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        }
        let grid = NSGridView(views: [
            [NSGridCell.emptyContentView, mode],
            [NSGridCell.emptyContentView, formatStyle],
            [firstLabel, first],
            [secondLabel, second],
            [NSGridCell.emptyContentView, position],
            [NSGridCell.emptyContentView, caseSensitive],
        ])
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.addArrangedSubview(grid)
        accessory.addArrangedSubview(example)
        accessory.frame = NSRect(x: 0, y: 0, width: 340, height: 200)
        changed()
    }

    /// The rename the controls describe now.
    var rename: BatchRename {
        switch mode.indexOfSelectedItem {
        case 0:
            return BatchRename(rule: .replace(find: first.stringValue, with: second.stringValue,
                                              caseSensitive: caseSensitive.state == .on))
        case 1:
            return BatchRename(rule: .add(text: first.stringValue, position: selectedPosition))
        default:
            let style: BatchRename.FormatStyle = switch formatStyle.indexOfSelectedItem {
            case 1: .counter
            case 2: .date
            default: .index
            }
            return BatchRename(rule: .format(base: first.stringValue, style: style, position: selectedPosition,
                                             start: Int(second.stringValue) ?? 1))
        }
    }

    private var selectedPosition: BatchRename.Position {
        position.indexOfSelectedItem == 1 ? .beforeName : .afterName
    }

    @objc private func changed() {
        let index = mode.indexOfSelectedItem
        formatStyle.isHidden = index != 2
        caseSensitive.isHidden = index != 0
        position.isHidden = index == 0
        second.isHidden = index == 1
        secondLabel.isHidden = index == 1
        switch index {
        case 0:
            firstLabel.stringValue = FilesStrings.renameFind
            secondLabel.stringValue = FilesStrings.renameReplaceWith
        case 1:
            firstLabel.stringValue = FilesStrings.renameText
        default:
            firstLabel.stringValue = FilesStrings.renameCustomFormat
            secondLabel.stringValue = FilesStrings.renameStartAt
            if second.stringValue.isEmpty { second.stringValue = "1" }
        }
        let preview = rename.plan(Array(names.prefix(1)), taken: []).first?.to ?? ""
        example.stringValue = FilesStrings.renameExample(preview)
    }
}

extension BatchRenameSheet: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) { changed() }
}
