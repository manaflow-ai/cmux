import Foundation

/// Parses `uiautomator dump` XML into a ``PhoneElement`` tree, frames in dp.
struct UIAutomatorTree {
    /// Pixels per dp of the dumped screen.
    let pixelsPerPoint: Double

    func parse(_ output: Data) throws -> PhoneElement {
        // The dump ends with a status line after the XML ("UI hierchary dumped to: /dev/tty").
        var text = String(decoding: output, as: UTF8.self)
        if let end = text.range(of: "</hierarchy>", options: .backwards) { text = String(text[..<end.upperBound]) }
        let parser = XMLParser(data: Data(text.utf8))
        let builder = Builder(pixelsPerPoint: max(pixelsPerPoint, 0.01))
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else { throw PhoneError.unreadable(what: "the UI Automator dump") }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        let pixelsPerPoint: Double
        var stack: [PhoneElement] = []
        var root: PhoneElement?

        init(pixelsPerPoint: Double) { self.pixelsPerPoint = pixelsPerPoint }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch name {
            case "hierarchy":
                stack.append(PhoneElement(role: "Screen", frame: PhoneRect(x: 0, y: 0, width: 0, height: 0)))
            case "node":
                let role = (attributes["class"] ?? "View").split(separator: ".").last.map(String.init) ?? "View"
                let text = attributes["text"] ?? ""
                let label = text.isEmpty ? (attributes["content-desc"] ?? "") : text
                stack.append(PhoneElement(role: role, label: label, identifier: attributes["resource-id"] ?? "",
                                          frame: frame(attributes["bounds"] ?? "")))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard name == "node" || name == "hierarchy", let done = stack.popLast() else { return }
            if stack.isEmpty { root = done } else { stack[stack.count - 1].children.append(done) }
        }

        /// "[105,525][420,630]" -> a rect in dp.
        func frame(_ bounds: String) -> PhoneRect {
            let numbers = bounds.split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Double($0) }
            guard numbers.count == 4 else { return PhoneRect(x: 0, y: 0, width: 0, height: 0) }
            let s = pixelsPerPoint
            return PhoneRect(x: numbers[0] / s, y: numbers[1] / s, width: (numbers[2] - numbers[0]) / s, height: (numbers[3] - numbers[1]) / s)
        }
    }
}
