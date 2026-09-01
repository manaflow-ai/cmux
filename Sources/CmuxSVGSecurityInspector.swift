import Foundation

/// Rejects SVG markup that can execute code or load external resources.
final class CmuxSVGSecurityInspector: NSObject, XMLParserDelegate {
    private var isSafe = true
    private var elementStack: [String] = []
    private var styleText: String?

    func parse(data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        return parsed && isSafe
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let loweredName = Self.localName(elementName)
        elementStack.append(loweredName)
        if loweredName == "style" {
            styleText = ""
        }
        if loweredName == "script" || loweredName == "foreignobject" {
            markUnsafe(parser)
            return
        }
        for (name, value) in attributeDict where !Self.isSafeSVGAttribute(name: name, value: value) {
            markUnsafe(parser)
            return
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard !elementStack.isEmpty else { return }
        if elementStack.last == "style",
           let styleText,
           !Self.isSafeSVGStyle(styleText) {
            markUnsafe(parser)
            return
        }
        elementStack.removeLast()
        if elementStack.last != "style" {
            self.styleText = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard elementStack.last == "style" else { return }
        styleText?.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard elementStack.last == "style" else { return }
        guard let text = String(data: CDATABlock, encoding: .utf8) else {
            markUnsafe(parser)
            return
        }
        styleText?.append(text)
    }

    func parser(
        _ parser: XMLParser,
        foundProcessingInstructionWithTarget target: String,
        data: String?
    ) {
        if target.lowercased() == "xml-stylesheet" { markUnsafe(parser) }
    }

    private func markUnsafe(_ parser: XMLParser) {
        isSafe = false
        parser.abortParsing()
    }

    private static func isSafeSVGAttribute(name: String, value: String) -> Bool {
        let qualifiedName = name.lowercased()
        let loweredName = localName(name)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let loweredValue = trimmedValue.lowercased()
        if qualifiedName == "xmlns" || qualifiedName.hasPrefix("xmlns:") { return true }
        if loweredName.hasPrefix("on") { return false }
        if loweredName == "style" { return isSafeSVGStyle(trimmedValue) }
        if loweredName == "href" {
            return isSafeSVGReference(trimmedValue)
        }
        // CSS escapes are meaningful in presentation attributes, so reject
        // them instead of trying to duplicate a browser's CSS tokenizer.
        if trimmedValue.contains("\\") { return false }
        if containsBlockedSVGValue(loweredValue) { return false }
        return !loweredValue.contains("url(") || containsOnlyInternalSVGURLs(trimmedValue)
    }

    private static func isSafeSVGStyle(_ value: String) -> Bool {
        let loweredValue = value.lowercased()
        guard !value.contains("\\"),
              !loweredValue.contains("@import"),
              !containsBlockedSVGValue(loweredValue) else { return false }
        return !loweredValue.contains("url(") || containsOnlyInternalSVGURLs(value)
    }

    private static func localName(_ qualifiedName: String) -> String {
        String(qualifiedName.split(separator: ":").last ?? Substring(qualifiedName))
            .lowercased()
    }

    private static func isSafeSVGReference(_ value: String) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return true }
        if trimmedValue.hasPrefix("#") { return true }
        if trimmedValue.lowercased().hasPrefix("url(") {
            return containsOnlyInternalSVGURLs(trimmedValue)
        }
        return false
    }

    private static func containsBlockedSVGValue(_ value: String) -> Bool {
        ["javascript:", "data:", "http://", "https://", "file://", "blob:"]
            .contains { value.contains($0) }
    }

    private static func containsOnlyInternalSVGURLs(_ value: String) -> Bool {
        let loweredValue = value.lowercased()
        var searchStart = loweredValue.startIndex
        while let range = loweredValue.range(
            of: "url(", options: [], range: searchStart..<loweredValue.endIndex
        ) {
            let contentStart = range.upperBound
            guard let closing = loweredValue[contentStart...].firstIndex(of: ")") else {
                return false
            }
            var reference = String(loweredValue[contentStart..<closing])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if (reference.hasPrefix("\"") && reference.hasSuffix("\"")) ||
                (reference.hasPrefix("'") && reference.hasSuffix("'")) {
                reference.removeFirst()
                reference.removeLast()
            }
            guard reference.hasPrefix("#") else { return false }
            searchStart = loweredValue.index(after: closing)
        }
        return true
    }
}
