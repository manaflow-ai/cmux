/// Main-thread milliseconds by area (bench frame log).
struct TranscriptPerf {
    var chunk = 0.0
    var render = 0.0
    var drawsOnMain = 0
    var prefetch = 0.0
    var place = 0.0
    var commit = 0.0
    var measure = 0.0

    mutating func reset() { self = TranscriptPerf() }
}
