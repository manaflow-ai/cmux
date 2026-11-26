func simulatorPresentationTimerIntervalNanoseconds(
    maximumFramesPerSecond: Int?
) -> Int {
    let framesPerSecond = min(max(maximumFramesPerSecond ?? 60, 1), 120)
    return Int((1_000_000_000 / Double(framesPerSecond)).rounded())
}
