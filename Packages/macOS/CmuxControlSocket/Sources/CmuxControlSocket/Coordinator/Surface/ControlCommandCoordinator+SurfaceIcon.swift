extension ControlCommandCoordinator {
    /// Parses a surface-icon mutation and calls the app's worker-lane seam.
    ///
    /// No handles, focus fallback, rendering, or main-actor hop occurs here.
    /// The app validates/rasterizes SVG off-main, then revalidates the target
    /// and lease at its minimal main-actor mutation boundary.
    ///
    /// - Parameters:
    ///   - params: The raw JSON parameters with explicit workspace and surface UUIDs.
    ///   - clear: Whether this is `surface.icon.clear` rather than `surface.icon.set`.
    ///   - context: The live app seam, explicitly passed for worker dispatch.
    /// - Returns: A validation failure or the app's authoritative lease result.
    public nonisolated func surfaceIcon(
        _ params: [String: JSONValue],
        clear: Bool,
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        let inputs: ControlSurfaceIconInputs
        do {
            inputs = try ControlSurfaceIconParser().parse(params, clear: clear)
        } catch let error as ControlSurfaceIconParser.Invalid {
            return .err(code: "invalid_params", message: error.message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: "Invalid surface icon parameters", data: nil)
        }
        guard let context else {
            return .err(code: "unavailable", message: "Surface icon context unavailable", data: nil)
        }
        return context.controlSurfaceIcon(inputs)
    }
}
