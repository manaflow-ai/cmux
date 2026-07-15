struct ChromiumScreencastConfiguration {
    let viewportWidth: Int
    let viewportHeight: Int

    var parameters: [String: CDPJSONValue] {
        [
            "format": .string("jpeg"),
            "quality": .number(75),
            "maxWidth": .number(Double(max(viewportWidth, 1) * 2)),
            "maxHeight": .number(Double(max(viewportHeight, 1) * 2)),
            "everyNthFrame": .number(2),
        ]
    }
}
