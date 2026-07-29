/// An array decoder that drops malformed elements while preserving valid ones.
struct LossyDecodableArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            let element = try container.decode(ElementContainer.self)
            if let value = element.value {
                elements.append(value)
            }
        }
        self.elements = elements
    }

    private struct ElementContainer: Decodable {
        let value: Element?

        init(from decoder: any Decoder) throws {
            value = try? Element(from: decoder)
        }
    }
}
