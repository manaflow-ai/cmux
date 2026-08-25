internal import CmuxBrowser

extension ControlCommandCoordinator {
    func browserEngineStrings() -> ControlBrowserEngineStrings {
        (context as? any ControlBrowserPanelContext)?.controlBrowserEngineStrings()
            ?? ControlBrowserEngineStrings(invalidOption: "Invalid browser engine", browserOnly: "Browser engine only")
    }

    /// Parses and validates the engine override shared by every v2 pane and
    /// surface creation entrypoint.
    func browserEngineParameter(
        _ params: [String: JSONValue]
    ) -> (engine: BrowserEngineKind?, error: ControlCallResult?) {
        let engine: BrowserEngineKind?
        if hasNonNull(params, "engine") {
            guard let rawEngine = string(params, "engine"),
                  let parsedEngine = BrowserEngineKind.parse(rawEngine) else {
                return (
                    nil,
                    .err(
                        code: "invalid_params",
                        message: browserEngineStrings().invalidOption,
                        data: .object(["engine": params["engine"] ?? .null])
                    )
                )
            }
            engine = parsedEngine
        } else {
            engine = nil
        }
        guard engine == nil || BrowserEngineKind.isBrowserPanelType(string(params, "type")) else {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: browserEngineStrings().browserOnly,
                    data: .object(["type": params["type"] ?? .null])
                )
            )
        }
        return (engine, nil)
    }
}
