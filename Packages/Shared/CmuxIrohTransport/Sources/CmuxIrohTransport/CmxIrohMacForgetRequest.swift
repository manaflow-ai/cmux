struct CmxIrohMacForgetRequest: Encodable {
    let bindingId: String
    let intent = "forget_mac"
}
