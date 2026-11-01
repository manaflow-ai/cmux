import Foundation

/// XML delegate with no entity, text, resource-reference, or extension-element support.
final class SurfaceIconSVGDocumentParser: NSObject, XMLParserDelegate {
    private let validator: SurfaceIconSVGValidator
    private var stack: [String] = []
    private var transformDepth: Int?
    private var nodes = 0
    private var attributeBytes = 0
    private var failed = false
    private var rootClosed = false

    var isValidDocument: Bool { !failed && rootClosed && stack.isEmpty && nodes > 0 }

    init(validator: SurfaceIconSVGValidator) { self.validator = validator }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        nodes += 1
        attributeBytes += attributes.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        guard nodes <= 256, attributeBytes <= 5120, stack.count < 32,
              ["svg", "g", "path", "rect", "circle"].contains(elementName),
              !rootClosed, stack.isEmpty ? elementName == "svg" : elementName != "svg" else {
            reject(parser); return
        }
        if !stack.isEmpty, let parent = stack.last, parent != "svg", parent != "g" {
            reject(parser); return
        }
        let common: Set<String> = ["fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin",
                                   "transform", "opacity", "fill-opacity", "stroke-opacity"]
        let geometry: Set<String>
        switch elementName {
        case "svg": geometry = ["xmlns", "viewBox", "width", "height"]
        case "path": geometry = ["d"]
        case "rect": geometry = ["x", "y", "width", "height", "rx", "ry"]
        case "circle": geometry = ["cx", "cy", "r"]
        default: geometry = []
        }
        guard Set(attributes.keys).isSubset(of: common.union(geometry)) else { reject(parser); return }
        if elementName == "svg" {
            guard let viewBox = attributes["viewBox"], let values = validator.numbers(viewBox),
                  values.count == 4, values[0] == 0, values[1] == 0,
                  values[2] >= 1, values[2] <= 128, values[3] >= 1, values[3] <= 128 else {
                reject(parser); return
            }
        }
        if elementName == "path", attributes["d"] == nil { reject(parser); return }
        for (name, value) in attributes {
            var valid: Bool
            switch name {
            case "xmlns": valid = value == "http://www.w3.org/2000/svg"
            case "viewBox": valid = true // Validated above, and only admitted on the root.
            case "fill", "stroke":
                valid = value == "none" || value.range(of: #"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#,
                                                       options: .regularExpression) != nil
            case "stroke-linecap": valid = ["butt", "round", "square"].contains(value)
            case "stroke-linejoin": valid = ["miter", "round", "bevel"].contains(value)
            case "d": valid = validator.validPath(value)
            case "transform":
                // Nested transforms multiply resource bounds. Keep the dialect simple and bounded.
                valid = transformDepth == nil && validator.validTransform(value)
            default:
                if let values = validator.numbers(value), values.count == 1 {
                    let number = values[0]
                    if ["opacity", "fill-opacity", "stroke-opacity"].contains(name) {
                        valid = (0...1).contains(number)
                    } else if ["width", "height", "r", "rx", "ry", "stroke-width"].contains(name) {
                        valid = number >= 0 && (elementName != "svg" || (number >= 1 && number <= 128))
                    } else {
                        valid = true
                    }
                } else {
                    valid = false
                }
            }
            guard valid else { reject(parser); return }
        }
        stack.append(elementName)
        if attributes["transform"] != nil { transformDepth = stack.count }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard stack.last == elementName else { reject(parser); return }
        if transformDepth == stack.count { transformDepth = nil }
        stack.removeLast()
        if stack.isEmpty { rootClosed = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reject(parser) }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { reject(parser) }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String,
                systemID: String?) -> Data? {
        reject(parser)
        return nil
    }

    private func reject(_ parser: XMLParser) {
        failed = true
        parser.abortParsing()
    }
}
