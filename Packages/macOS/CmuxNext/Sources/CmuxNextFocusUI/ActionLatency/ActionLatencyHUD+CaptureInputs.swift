package import CmuxNextInputCore

extension ActionLatencyHUD {
    /// The `latency-hud` capture scene's inputs, oldest first: a terminal key shown in 6.9 ms (under one 120 Hz
    /// frame), a page scroll shown in 14.8 ms (over it, the danger color) and a sidebar click that never reached a
    /// frame (tertiary).
    package static var captureInputs: [InputLatencySlot] {
        let ms: UInt64 = 1_000_000
        var key = InputLatencySlot(kind: .keyPress, target: .terminal, entrypoint: .person, causedFrameUpdate: true)
        key.generated = 1_000 * ms
        key.arrivedMain = key.generated + ms * 4 / 10
        key.dispatchEnd = key.generated + ms * 12 / 10
        key.daemonReceived = key.generated + ms * 15 / 10
        key.echoSent = key.generated + 3 * ms
        key.contentSubmitted = key.generated + ms * 55 / 10
        key.presented = key.generated + ms * 69 / 10
        var scroll = InputLatencySlot(kind: .scrollUpdate, target: .chromiumPage, entrypoint: .person, causedFrameUpdate: true)
        scroll.generated = 1_100 * ms
        scroll.dispatchEnd = scroll.generated + 2 * ms
        scroll.contentSubmitted = scroll.generated + 11 * ms
        scroll.presented = scroll.generated + ms * 148 / 10
        var click = InputLatencySlot(kind: .mousePress, target: .sidebar, entrypoint: .person)
        click.generated = 1_200 * ms
        click.dispatchEnd = click.generated + ms
        return [key, scroll, click]
    }
}
