import AppKit
import Runestone

struct VendoredRunestoneSmokeSnapshot {
    let text: String
    let isEditable: Bool
    let isSelectable: Bool
    let themeTypeName: String
}

enum VendoredRunestoneSupport {
    static func makeSmokeSnapshot() -> VendoredRunestoneSmokeSnapshot {
        let editor = TextView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        editor.theme = DefaultTheme()
        editor.isEditable = true
        editor.isSelectable = true
        editor.text = "# cmux\nVendored Runestone\n"

        return VendoredRunestoneSmokeSnapshot(
            text: editor.text,
            isEditable: editor.isEditable,
            isSelectable: editor.isSelectable,
            themeTypeName: String(describing: type(of: editor.theme))
        )
    }
}
