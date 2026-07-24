@preconcurrency import AVFoundation
import CmuxSimulator
import CoreImage

struct SimulatorCameraPlayback: Sendable {
    private let surfaceRing: SimulatorCameraSurfaceRing
    private let timing: any SimulatorCameraTiming

    init(surfaceRing: SimulatorCameraSurfaceRing, timing: any SimulatorCameraTiming) {
        self.surfaceRing = surfaceRing
        self.timing = timing
    }

    @concurrent func playPlaceholder() async {
        var frame: UInt64 = 0
        while !Task.isCancelled {
            let phase = Double(frame % 180) / 180 * .pi * 2
            let left = CIImage(
                color: CIColor(
                    red: 0.20 + 0.12 * sin(phase),
                    green: 0.30 + 0.10 * sin(phase + 2),
                    blue: 0.58 + 0.12 * sin(phase + 4)
                )
            ).cropped(
                to: CGRect(
                    x: 0,
                    y: 0,
                    width: SimulatorCameraSurfaceRing.width / 2,
                    height: SimulatorCameraSurfaceRing.height
                )
            )
            let right = CIImage(
                color: CIColor(
                    red: 0.58 + 0.12 * sin(phase + 3),
                    green: 0.22 + 0.10 * sin(phase + 5),
                    blue: 0.38 + 0.12 * sin(phase + 1)
                )
            ).cropped(
                to: CGRect(
                    x: SimulatorCameraSurfaceRing.width / 2,
                    y: 0,
                    width: SimulatorCameraSurfaceRing.width / 2,
                    height: SimulatorCameraSurfaceRing.height
                )
            )
            surfaceRing.publish(left.composited(over: right), fillsFrame: true)
            frame &+= 1
            do {
                try await timing.sleep(for: .milliseconds(33))
            } catch {
                return
            }
        }
    }

    @concurrent func playVideo(url: URL, loops: Bool) async {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first else { return }
        let loopDelayMilliseconds: Int64?
        if loops {
            guard let duration = try? await asset.load(.duration),
                  let delay = Self.loopDelayMilliseconds(
                      assetDurationSeconds: CMTimeGetSeconds(duration)
                  ) else { return }
            loopDelayMilliseconds = delay
        } else {
            loopDelayMilliseconds = nil
        }
        repeat {
            guard !Task.isCancelled,
                  let (reader, output) = try? makeReader(asset: asset, track: track)
            else { return }
            let playbackStart = timing.now()
            var firstPresentationTime: Double?
            while !Task.isCancelled, let sampleBuffer = output.copyNextSampleBuffer() {
                let presentationTime = CMTimeGetSeconds(
                    CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                )
                if presentationTime.isFinite {
                    if firstPresentationTime == nil { firstPresentationTime = presentationTime }
                    guard let delayMilliseconds = Self.delayMilliseconds(
                        firstPresentationTime: firstPresentationTime ?? presentationTime,
                        presentationTime: presentationTime
                    ) else {
                        reader.cancelReading()
                        return
                    }
                    do {
                        try await timing.sleep(
                            until: playbackStart + .milliseconds(
                                delayMilliseconds
                            ),
                            tolerance: .milliseconds(2)
                        )
                    } catch {
                        reader.cancelReading()
                        return
                    }
                }
                if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    surfaceRing.publish(pixelBuffer: pixelBuffer, fillsFrame: false)
                }
            }
            let completed = reader.status == .completed
            reader.cancelReading()
            if !completed { return }
            if let loopDelayMilliseconds {
                do {
                    try await timing.sleep(
                        until: playbackStart + .milliseconds(loopDelayMilliseconds),
                        tolerance: .milliseconds(2)
                    )
                } catch {
                    return
                }
            }
        } while loops && !Task.isCancelled
    }

    static func delayMilliseconds(
        firstPresentationTime: Double,
        presentationTime: Double
    ) -> Int64? {
        guard firstPresentationTime.isFinite, presentationTime.isFinite else { return nil }
        let elapsed = max(0, presentationTime - firstPresentationTime)
        let milliseconds = (elapsed * 1_000).rounded()
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds < Double(Int64.max) else { return nil }
        return Int64(milliseconds)
    }

    static func loopDelayMilliseconds(assetDurationSeconds: Double) -> Int64? {
        guard assetDurationSeconds.isFinite, assetDurationSeconds > 0 else { return nil }
        let milliseconds = ceil(assetDurationSeconds * 1_000)
        guard milliseconds.isFinite,
              milliseconds >= 1,
              milliseconds < Double(Int64.max) else { return nil }
        return Int64(milliseconds)
    }

    private func makeReader(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                "AVFoundation rejected BGRA output for the synthetic-camera video."
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                reader.error?.localizedDescription ?? "The synthetic-camera video could not start."
            )
        }
        return (reader, output)
    }
}
