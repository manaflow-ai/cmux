struct ChromiumIsolatedWorldConfiguration {
    let frameID: String

    var parameters: [String: CDPJSONValue] {
        [
            "frameId": .string(frameID),
            "worldName": .string("cmux.browser.automation"),
            "grantUniversalAccess": .bool(true),
        ]
    }
}
