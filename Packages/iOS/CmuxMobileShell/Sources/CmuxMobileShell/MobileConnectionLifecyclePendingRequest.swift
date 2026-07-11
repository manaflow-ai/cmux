struct MobileConnectionLifecyclePendingRequest {
    var id: UInt64?
    var trigger: MobileConnectionLifecycleTrigger
    var reconnectStackUserID: String?
}
