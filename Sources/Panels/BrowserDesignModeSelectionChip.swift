import Foundation

/// SF Symbols describing the kind of element a design-mode selection
/// references, so a stack of prompt tokens reads at a glance (photo vs text
/// vs button vs container). Shared by the composer's inline token cells.
enum BrowserDesignModeTagSymbol {
    static func symbol(forTag tag: String) -> String {
        switch tag.lowercased() {
        case "img", "picture": "photo"
        case "video": "play.rectangle"
        case "audio": "speaker.wave.2"
        case "a": "link"
        case "button": "cursorarrow.click"
        case "input", "textarea", "select", "form": "character.cursor.ibeam"
        case "h1", "h2", "h3", "h4", "h5", "h6": "textformat.size"
        case "p", "span", "label", "strong", "em", "b", "i", "blockquote": "text.alignleft"
        case "ul", "ol", "li": "list.bullet"
        case "table", "thead", "tbody", "tr", "td", "th": "tablecells"
        case "svg", "canvas", "path": "paintbrush.pointed"
        case "iframe": "globe"
        case "region": "crop"
        default: "square.dashed"
        }
    }
}
