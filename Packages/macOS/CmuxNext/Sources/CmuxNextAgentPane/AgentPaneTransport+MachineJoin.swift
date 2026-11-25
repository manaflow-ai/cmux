extension AgentPaneTransport {
    /// The method of Door A's join (webviews machineJoin.ts; acpmux server/machine_join_ssh.rs).
    static let machineJoinMethod = "_acpmux/machine_join_ssh"

    /// A join of a machine over ssh goes with the person's access token, which only the host holds:
    /// it is added here, after every rule read the page's own frame (the page may not send
    /// `accessToken`, ``AcpmuxPaneMethods/knownParams``). Signed out, the join is refused here and
    /// acpmux never runs it; the page's line says to sign in. Any other frame is untouched.
    func withMachineJoinToken(_ facts: Facts, _ box: FrameBox, socket: AcpmuxPaneSocket) async -> Step? {
        guard !facts.isFirst, facts.method == Self.machineJoinMethod else { return nil }
        guard let token = await machineJoinToken(), !token.isEmpty else {
            return Self.refuse(.refuse(.methodRefused, method: facts.method, requestID: facts.pageID), socket: socket,
                               reason: "not_signed_in")
        }
        box.setParam("accessToken", token)
        return nil
    }
}
