import Foundation

/// XML-parser delegate that walks SVG markup and decides whether it is safe to
/// render, driving the safety verdict surfaced by ``SVGMarkupValidator``.
///
/// It is a stateful, single-use parse engine (it tracks the open-element stack
/// and a running `isSafe` flag), so it stays a reference type and a fresh
/// instance is created per parse. External entity resolution and namespace
/// processing are disabled before parsing. On the first unsafe construct it
/// aborts the parse and reports `false`.
final class SVGSecurityInspector: NSObject, XMLParserDelegate {
    private var isSafe = true
    private var elementStack: [String] = []

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
        let loweredName = elementName.lowercased()
        elementStack.append(loweredName)

        if loweredName == "script" || loweredName == "foreignobject" {
            markUnsafe(parser)
            return
        }

        for (name, value) in attributeDict {
            guard Self.isSafeSVGAttribute(name: name, value: value) else {
                markUnsafe(parser)
                return
            }
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard !elementStack.isEmpty else { return }
        elementStack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard elementStack.last == "style" else { return }
        guard Self.isSafeSVGStyle(string) else {
            markUnsafe(parser)
            return
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard elementStack.last == "style",
              let text = String(data: CDATABlock, encoding: .utf8) else {
            return
        }
        guard Self.isSafeSVGStyle(text) else {
            markUnsafe(parser)
            return
        }
    }

    func parser(
        _ parser: XMLParser,
        foundProcessingInstructionWithTarget target: String,
        data: String?
    ) {
        if target.lowercased() == "xml-stylesheet" {
            markUnsafe(parser)
        }
    }

    private func markUnsafe(_ parser: XMLParser) {
        isSafe = false
        parser.abortParsing()
    }

    private static func isSafeSVGAttribute(name: String, value: String) -> Bool {
        let loweredName = name.lowercased()
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let loweredValue = trimmedValue.lowercased()

        if loweredName.hasPrefix("on") {
            return false
        }

        if loweredName == "xmlns" || loweredName.hasPrefix("xmlns:") {
            return true
        }

        if loweredName == "href" || loweredName == "xlink:href" {
            return isSafeSVGReference(trimmedValue)
        }

        if containsBlockedSVGValue(loweredValue) {
            return false
        }

        if loweredValue.contains("url(") {
            return containsOnlyInternalSVGURLs(trimmedValue)
        }

        return true
    }

    private static func isSafeSVGStyle(_ value: String) -> Bool {
        let loweredValue = value.lowercased()
        guard !loweredValue.contains("@import"),
              !containsBlockedSVGValue(loweredValue) else {
            return false
        }
        if loweredValue.contains("url(") {
            return containsOnlyInternalSVGURLs(value)
        }
        return true
    }

    private static func isSafeSVGReference(_ value: String) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return true }
        if trimmedValue.hasPrefix("#") {
            return true
        }
        if trimmedValue.lowercased().hasPrefix("url(") {
            return containsOnlyInternalSVGURLs(trimmedValue)
        }
        return false
    }

    private static func containsBlockedSVGValue(_ value: String) -> Bool {
        let blockedFragments = [
            "javascript:",
            "data:",
            "http://",
            "https://",
            "file://",
            "blob:"
        ]
        return blockedFragments.contains { value.contains($0) }
    }

    private static func containsOnlyInternalSVGURLs(_ value: String) -> Bool {
        let loweredValue = value.lowercased()
        var searchStart = loweredValue.startIndex

        while let range = loweredValue.range(
            of: "url(",
            options: [],
            range: searchStart..<loweredValue.endIndex
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

            guard reference.hasPrefix("#") else {
                return false
            }

            searchStart = loweredValue.index(after: closing)
        }

        return true
    }
}
