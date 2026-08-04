func simulatorPresentationTimerIntervalNanoseconds(
    maximumFramesPerSecond: Int?
) -> Int {
    let framesPerSecond = min(max(maximumFramesPerSecond ?? 60, 1), 120)
    return Int((1_000_000_000 / Double(framesPerSecond)).rounded())
}

func simulatorPresentationFramesPerSecond(
    displayMaximumFramesPerSecond: Int?,
    transportMaximumFramesPerSecond: Int?
) -> Int? {
    switch (
        displayMaximumFramesPerSecond,
        transportMaximumFramesPerSecond
    ) {
    case let (display?, transport?):
        return min(display, transport)
    case let (display?, nil):
        return display
    case let (nil, transport?):
        return transport
    case (nil, nil):
        return nil
    }
}
