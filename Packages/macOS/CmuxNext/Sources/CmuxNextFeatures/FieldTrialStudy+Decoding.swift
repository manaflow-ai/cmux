public import Foundation

/// The `Studies` wire form (FieldTrialStudy's doc comment shows one entry).
extension FieldTrialStudy: Decodable {
    private enum Keys: String, CodingKey {
        case name, feature, arms, channel
        case minBuild = "min_build"
        case maxBuild = "max_build"
    }

    private enum ArmKeys: String, CodingKey {
        case name, weight, state
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        var arms: [Arm] = []
        var armList = try container.nestedUnkeyedContainer(forKey: .arms)
        while !armList.isAtEnd {
            let arm = try armList.nestedContainer(keyedBy: ArmKeys.self)
            let name = try arm.decode(String.self, forKey: .name)
            let weight = try arm.decode(Int.self, forKey: .weight)
            let isEnabled: Bool
            switch try arm.decode(String.self, forKey: .state) {
            case "on": isEnabled = true
            case "off": isEnabled = false
            default: throw FieldTrialError.invalidState(arm: name)
            }
            arms.append(Arm(name: name, weight: weight, isEnabled: isEnabled))
        }
        let channelNames: [String]?
        if let one = try? container.decodeIfPresent(String.self, forKey: .channel) {
            channelNames = [one]
        } else {
            channelNames = try container.decodeIfPresent([String].self, forKey: .channel)
        }
        var channels = Self.defaultChannels
        if let channelNames {
            channels = []
            for channelName in channelNames {
                guard let channel = Feature.Channel(rawValue: channelName) else { throw FieldTrialError.unknownChannel(channelName) }
                channels.insert(channel)
            }
        }
        try self.init(
            name: container.decodeIfPresent(String.self, forKey: .name),
            feature: container.decode(String.self, forKey: .feature),
            arms: arms,
            channels: channels,
            minBuild: Self.build(container, .minBuild),
            maxBuild: Self.build(container, .maxBuild)
        )
    }

    /// A build bound written as text (`"1200"`) or as a number (`1200`).
    private static func build(_ container: KeyedDecodingContainer<Keys>, _ key: Keys) throws -> String? {
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return text }
        return try container.decodeIfPresent(Int.self, forKey: key).map(String.init)
    }

    /// One entry of a `Studies` list: the study, or why it is rejected, so
    /// one bad entry never drops the others (Chrome skips an invalid study
    /// and keeps the rest of the seed, VariationsSeedProcessor).
    public nonisolated struct Entry: Decodable, Sendable, Hashable {
        public let result: Result<FieldTrialStudy, FieldTrialRejection>

        public init(from decoder: any Decoder) {
            let declared = try? decoder.container(keyedBy: Keys.self)
            let name = (try? declared?.decodeIfPresent(String.self, forKey: .name))
                ?? (try? declared?.decodeIfPresent(String.self, forKey: .feature))
            do {
                let study = try FieldTrialStudy(from: decoder)
                result = .success(study)
            } catch let error as FieldTrialError {
                result = .failure(FieldTrialRejection(study: name, error: error))
            } catch let error as DecodingError {
                result = .failure(FieldTrialRejection(study: name, error: .malformed(Self.reason(error, below: decoder.codingPath.count))))
            } catch {
                result = .failure(FieldTrialRejection(study: name, error: .malformed(String(describing: error))))
            }
        }

        /// The decoder's reason, with the key path inside the entry (`arms.0.weight: ...`).
        private static func reason(_ error: DecodingError, below depth: Int) -> String {
            let path: [any CodingKey]
            let detail: String
            switch error {
            case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
                path = context.codingPath
                detail = context.debugDescription
            case let .keyNotFound(key, context):
                path = context.codingPath + [key]
                detail = "missing"
            @unknown default:
                path = []
                detail = String(describing: error)
            }
            let keys = path.dropFirst(depth).map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return keys.isEmpty ? detail : "\(keys): \(detail)"
        }
    }

    /// The studies of a `Studies` JSON array, in document order, and the
    /// entries rejected. A value that is not an array rejects everything.
    public static func decodeList(_ data: Data) -> (studies: [FieldTrialStudy], rejected: [FieldTrialRejection]) {
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            return ([], [FieldTrialRejection(study: nil, error: .malformed("Studies is not a list of objects"))])
        }
        var studies: [FieldTrialStudy] = []
        var rejected: [FieldTrialRejection] = []
        for entry in entries {
            switch entry.result {
            case let .success(study): studies.append(study)
            case let .failure(rejection): rejected.append(rejection)
            }
        }
        return (studies, rejected)
    }
}
