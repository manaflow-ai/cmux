import CCmuxWgTun

/// The Rust WireGuard engine (`cmux-wg-tun`) behind an actor, so start, path changes and stop
/// never overlap however NetworkExtension delivers its callbacks.
actor TunnelEngine {
    private var handle: OpaquePointer?

    /// Starts the engine on the provider's utun fd with the completed wg-quick config.
    func start(wgQuick: String) throws(ProviderError) {
        stop()
        let fd = cmux_wg_tun_find_utun_fd()
        guard fd >= 0 else { throw .noTunnelInterface }
        var reason = [CChar](repeating: 0, count: 512)
        let started = wgQuick.withCString { config in
            cmux_wg_tun_start(config, fd, &reason, reason.count)
        }
        guard let started else {
            throw .engine(String(decoding: reason.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self))
        }
        handle = started
    }

    /// The default route changed: rebind the UDP socket and re-handshake.
    func networkChanged() {
        if let handle { cmux_wg_tun_network_changed(handle) }
    }

    /// Bytes each way and the last handshake, for the app's status.
    func stats() -> CmuxWgTunStats? {
        guard let handle else { return nil }
        var stats = CmuxWgTunStats()
        cmux_wg_tun_stats(handle, &stats)
        return stats
    }

    func stop() {
        if let handle { cmux_wg_tun_stop(handle) }
        handle = nil
    }
}
