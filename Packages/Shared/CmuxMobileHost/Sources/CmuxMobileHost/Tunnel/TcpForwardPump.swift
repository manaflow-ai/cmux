import CmuxMobileLink
import CmuxMobileWire
import Foundation

/// Moves bytes between one `tcp.forward` channel and its loopback socket.
/// Each direction waits for its previous write (link credit one way, the
/// socket the other), so a stalled side holds at most one channel budget.
struct TcpForwardPump {
    let channel: MobileChannel
    let socket: any MobileLoopbackSocket
    let gate: MobileSessionGate
    let chunkBytes: Int

    func run() async {
        await withTaskGroup(of: TcpForwardEnd.self) { group in
            group.addTask { await socketToPhone() }
            group.addTask { await phoneToSocket() }
            var socketDone = false
            var phoneDone = false
            for await end in group {
                switch end {
                case .socketFinished:
                    socketDone = true
                case .phoneFinished:
                    phoneDone = true
                case .socketFailed:
                    await socket.close()
                    await channel.close(code: "tunnel.reset", message: "the connection on the Mac failed")
                    return
                case .phoneClosed:
                    await socket.close()
                    await channel.close()
                    return
                case .revoked:
                    await socket.close()
                    await channel.abort()
                    return
                }
                if socketDone && phoneDone {
                    await socket.close()
                    await channel.close()
                    return
                }
            }
        }
    }

    private func socketToPhone() async -> TcpForwardEnd {
        while true {
            let data: Data?
            do {
                data = try await socket.read(maximum: chunkBytes)
            } catch {
                return .socketFailed
            }
            guard await gate.isOpen else { return .revoked }
            guard let data else {
                return (try? await channel.send(binary: Data(), flags: .fin)) == nil ? .phoneClosed : .socketFinished
            }
            guard (try? await channel.send(binary: data)) != nil else { return .phoneClosed }
        }
    }

    private func phoneToSocket() async -> TcpForwardEnd {
        while true {
            switch await channel.receive() {
            case .binary(let data, let flags):
                guard await gate.isOpen else { return .revoked }
                if !data.isEmpty {
                    do {
                        try await socket.write(data)
                    } catch {
                        return .socketFailed
                    }
                }
                if flags.contains(.fin) {
                    await socket.finishWriting()
                    return .phoneFinished
                }
            case .json(let value):
                if case .channelClose? = try? MobileFrame(value: value) { return .phoneClosed }
            case .gap, .closed:
                return .phoneClosed
            }
        }
    }
}
