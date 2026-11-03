import CmuxNextControl

/// `workspace.expect_window` (``ControlWorkspaceWindowExpectation``, #32989): files an announced CLI create's
/// workspace into the window it names once the daemon reports it.
extension WindowManager {
    func expectWindowControlMethods() -> [ControlMethod] {
        [.mainActor(ControlWorkspaceWindowExpectation.method) { [weak self] call in
            guard let self else { return .value(["window": .null]) }
            return .value(try expectCreate(call.params, topology: call.snapshot.topology))
        }]
    }

    func expectCreate(_ params: [String: JSONValue], topology: ControlTopology) throws -> JSONValue {
        let expected = try ControlWorkspaceWindowExpectation(params: params, in: topology) { registry.value.window($0)?.isOpen == true }
        if let window = expected.window { claims.expected.expect(key: expected.key, window: window, shows: expected.shows) }
        return expected.reply
    }
}
