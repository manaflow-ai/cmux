# CmuxSudoBrokerUI

`CmuxSudoBrokerUI` projects the authoritative `CmuxSudoBroker` event stream
into one review window per request. The coordinator owns presentation state;
SwiftUI views only render that state and forward user decisions.

Tests construct `SudoApprovalCoordinator` with a broker conforming to
`SudoBrokerServing` and a recording `SudoApprovalPresenting` implementation,
so no app launch or user filesystem is required.
