struct CmxIrohStaleBindingRevocationRequest: Encodable {
    let bindingId: String
    let intent = "revoke_stale"
}
