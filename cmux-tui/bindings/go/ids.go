package cmux

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
)

type MachineID string
type SessionID string
type WorkspaceID string
type ScreenID string
type PaneID string
type TabID string
type TerminalID string
type BrowserID string
type ConnectedClientID string
type SplitID string
type NotificationID string
type AgentID string
type StreamID string
type ProjectionID string
type PairingRequestID string
type SidebarViewID string

type opaqueID interface {
	~string
}

// TabContentID is exactly one typed terminal or browser ID.
type TabContentID interface {
	fmt.Stringer
	tabContentID()
}

func (TerminalID) tabContentID() {}
func (BrowserID) tabContentID()  {}

func ParseMachineID(value string) (MachineID, error) {
	return parseID[MachineID](value, "machine")
}
func ParseSessionID(value string) (SessionID, error) {
	return parseID[SessionID](value, "session")
}
func ParseWorkspaceID(value string) (WorkspaceID, error) {
	return parseID[WorkspaceID](value, "ws")
}
func ParseScreenID(value string) (ScreenID, error) {
	return parseID[ScreenID](value, "screen")
}
func ParsePaneID(value string) (PaneID, error) {
	return parseID[PaneID](value, "pane")
}
func ParseTabID(value string) (TabID, error) {
	return parseID[TabID](value, "tab")
}
func ParseTerminalID(value string) (TerminalID, error) {
	return parseID[TerminalID](value, "term")
}
func ParseBrowserID(value string) (BrowserID, error) {
	return parseID[BrowserID](value, "browser")
}
func ParseConnectedClientID(value string) (ConnectedClientID, error) {
	return parseID[ConnectedClientID](value, "client")
}
func ParseSplitID(value string) (SplitID, error) {
	return parseID[SplitID](value, "split")
}
func ParseNotificationID(value string) (NotificationID, error) {
	return parseID[NotificationID](value, "notification")
}
func ParseAgentID(value string) (AgentID, error) {
	return parseID[AgentID](value, "agent")
}
func ParseStreamID(value string) (StreamID, error) {
	return parseID[StreamID](value, "stream")
}
func ParseProjectionID(value string) (ProjectionID, error) {
	return parseID[ProjectionID](value, "projection")
}
func ParsePairingRequestID(value string) (PairingRequestID, error) {
	return parseID[PairingRequestID](value, "pairing")
}
func ParseSidebarViewID(value string) (SidebarViewID, error) {
	return parseID[SidebarViewID](value, "sidebar_view")
}

func parseID[T opaqueID](value, prefix string) (T, error) {
	var zero T
	payload, ok := strings.CutPrefix(value, prefix+"_")
	if !ok || len(payload) != 32 {
		return zero, fmt.Errorf("%w: expected %s_ followed by 32 lowercase hexadecimal characters", ErrInvalidID, prefix)
	}
	decoded, err := hex.DecodeString(payload)
	if err != nil || len(decoded) != 16 || strings.ToLower(payload) != payload {
		return zero, fmt.Errorf("%w: expected %s_ followed by 32 lowercase hexadecimal characters", ErrInvalidID, prefix)
	}
	return T(value), nil
}

func unmarshalID[T opaqueID](data []byte, prefix string, target *T) error {
	var value string
	if err := json.Unmarshal(data, &value); err != nil {
		return fmt.Errorf("%w: %s ID must be a JSON string", ErrInvalidID, prefix)
	}
	parsed, err := parseID[T](value, prefix)
	if err != nil {
		return err
	}
	*target = parsed
	return nil
}

func idString[T opaqueID](id T) string { return string(id) }

type SelectorKind uint8

const (
	SelectorID SelectorKind = iota + 1
	SelectorCurrent
	SelectorName
)

// Selector is a typed ID, current-resource marker, or exact name. Names are
// always encoded with the name: prefix so ID-shaped names stay unambiguous.
type Selector[T opaqueID] struct {
	kind  SelectorKind
	id    T
	name  string
	valid bool
}

func SelectID[T opaqueID](id T) Selector[T] {
	return Selector[T]{kind: SelectorID, id: id, valid: id != ""}
}

func SelectCurrent[T opaqueID]() Selector[T] {
	return Selector[T]{kind: SelectorCurrent, valid: true}
}

func SelectName[T opaqueID](name string) Selector[T] {
	return Selector[T]{kind: SelectorName, name: name, valid: true}
}

func (s Selector[T]) Kind() SelectorKind { return s.kind }
func (s Selector[T]) ID() (T, bool)      { return s.id, s.valid && s.kind == SelectorID }
func (s Selector[T]) Name() (string, bool) {
	return s.name, s.valid && s.kind == SelectorName
}

func (s Selector[T]) String() string {
	switch s.kind {
	case SelectorID:
		return string(s.id)
	case SelectorCurrent:
		return "current"
	case SelectorName:
		return "name:" + s.name
	default:
		return ""
	}
}

func (s Selector[T]) MarshalJSON() ([]byte, error) {
	if !s.valid {
		return nil, fmt.Errorf("%w: zero selector", ErrInvalidSelector)
	}
	return json.Marshal(s.String())
}

func validateSelector[T opaqueID](selector Selector[T]) error {
	if !selector.valid {
		return fmt.Errorf("%w: zero selector", ErrInvalidSelector)
	}
	switch selector.kind {
	case SelectorID:
		if selector.id == "" {
			return fmt.Errorf("%w: empty resource ID", ErrInvalidSelector)
		}
	case SelectorCurrent, SelectorName:
	default:
		return fmt.Errorf("%w: unknown selector kind", ErrInvalidSelector)
	}
	return nil
}

func (id MachineID) String() string         { return idString(id) }
func (id SessionID) String() string         { return idString(id) }
func (id WorkspaceID) String() string       { return idString(id) }
func (id ScreenID) String() string          { return idString(id) }
func (id PaneID) String() string            { return idString(id) }
func (id TabID) String() string             { return idString(id) }
func (id TerminalID) String() string        { return idString(id) }
func (id BrowserID) String() string         { return idString(id) }
func (id ConnectedClientID) String() string { return idString(id) }
func (id SplitID) String() string           { return idString(id) }
func (id NotificationID) String() string    { return idString(id) }
func (id AgentID) String() string           { return idString(id) }
func (id StreamID) String() string          { return idString(id) }
func (id ProjectionID) String() string      { return idString(id) }
func (id PairingRequestID) String() string  { return idString(id) }
func (id SidebarViewID) String() string     { return idString(id) }

func (id *MachineID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "machine", id)
}
func (id *SessionID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "session", id)
}
func (id *WorkspaceID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "ws", id)
}
func (id *ScreenID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "screen", id)
}
func (id *PaneID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "pane", id)
}
func (id *TabID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "tab", id)
}
func (id *TerminalID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "term", id)
}
func (id *BrowserID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "browser", id)
}
func (id *ConnectedClientID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "client", id)
}
func (id *SplitID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "split", id)
}
func (id *NotificationID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "notification", id)
}
func (id *AgentID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "agent", id)
}
func (id *StreamID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "stream", id)
}
func (id *ProjectionID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "projection", id)
}
func (id *PairingRequestID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "pairing", id)
}
func (id *SidebarViewID) UnmarshalJSON(data []byte) error {
	return unmarshalID(data, "sidebar_view", id)
}
