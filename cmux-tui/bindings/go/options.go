package cmux

import (
	"fmt"
	"unicode/utf8"
)

// Extra fields are copied before typed fields are applied. This permits
// forward-compatible callers without allowing Extra to override typed fields.
type ReadOptions struct{ Extra map[string]JSONValue }
type MutationOptions struct {
	IdempotencyKey   string
	ExpectedRevision *Decimal
	CorrelationKey   string
	Extra            map[string]JSONValue
}
type ControlOptions struct{ Extra map[string]JSONValue }
type StreamOptions struct{ Extra map[string]JSONValue }

// NullableString represents a three-state optional nullable field. Its zero
// value omits the field, NullString sends JSON null, and ValueString sends the
// exact string, including empty, whitespace, and Unicode.
type NullableString struct {
	Present bool
	Value   *string
}

type NullableBool struct {
	Present bool
	Value   *bool
}

type NullableStringMap struct {
	Present bool
	Value   map[string]string
}

func NullString() NullableString { return NullableString{Present: true} }

func ValueString(value string) NullableString {
	return NullableString{Present: true, Value: &value}
}

func NullBool() NullableBool { return NullableBool{Present: true} }

func ValueBool(value bool) NullableBool {
	return NullableBool{Present: true, Value: &value}
}

func NullStringMap() NullableStringMap {
	return NullableStringMap{Present: true}
}

func ValueStringMap(value map[string]string) NullableStringMap {
	return NullableStringMap{Present: true, Value: value}
}

func OptionalString(value string) *string { return &value }
func OptionalBool(value bool) *bool       { return &value }
func OptionalUint16(value uint16) *uint16 { return &value }
func OptionalUint32(value uint32) *uint32 { return &value }
func OptionalInt32(value int32) *int32    { return &value }
func OptionalFloat64(value float64) *float64 {
	return &value
}

type MachineListOptions struct{ ReadOptions }

type SessionListOptions struct{ ReadOptions }
type SessionOpenOptions struct {
	MutationOptions
	Session Selector[SessionID]
}
type SessionSnapshotOptions struct{ ReadOptions }
type SessionCreationResolveOptions struct{ ReadOptions }
type SessionEventsOptions struct {
	StreamOptions
	Cursor *Cursor
}
type JournalStart string

const (
	JournalStartTail      JournalStart = "tail"
	JournalStartBeginning JournalStart = "beginning"
)

type JournalSubjectFilter struct {
	Kind *string `json:"kind,omitempty"`
	ID   *string `json:"id,omitempty"`
}
type JournalRegexField string

const (
	JournalRegexFieldKind           JournalRegexField = "kind"
	JournalRegexFieldSubjects       JournalRegexField = "subjects"
	JournalRegexFieldPayload        JournalRegexField = "payload"
	JournalRegexFieldRecord         JournalRegexField = "record"
	JournalRegexFieldTerminalOutput JournalRegexField = "terminal_output"
)

type JournalRegexFilter struct {
	Pattern       string            `json:"pattern"`
	Field         JournalRegexField `json:"field,omitempty"`
	CaseSensitive *bool             `json:"case_sensitive,omitempty"`
}
type JournalFilter struct {
	Kinds          []string               `json:"kinds,omitempty"`
	Classes        []JournalClass         `json:"classes,omitempty"`
	Subjects       []JournalSubjectFilter `json:"subjects,omitempty"`
	MaxSensitivity *JournalSensitivity    `json:"max_sensitivity,omitempty"`
	Regex          *JournalRegexFilter    `json:"regex,omitempty"`
}
type SessionJournalOptions struct {
	StreamOptions
	Cursor *Cursor
	Start  *JournalStart
	Follow *bool
	Filter *JournalFilter
}

func (o SessionJournalOptions) validate() error {
	if o.Cursor != nil && o.Start != nil {
		return fmt.Errorf("%w: journal cursor and start are mutually exclusive", ErrInvalidArgument)
	}
	if o.Start != nil && *o.Start != JournalStartTail && *o.Start != JournalStartBeginning {
		return fmt.Errorf("%w: journal start must be tail or beginning", ErrInvalidArgument)
	}
	if o.Filter == nil {
		return nil
	}
	if o.Filter.MaxSensitivity != nil {
		switch *o.Filter.MaxSensitivity {
		case JournalSensitivityPublic, JournalSensitivityMetadata, JournalSensitivitySensitive:
		case JournalSensitivitySecret:
			return fmt.Errorf("%w: secret journal records are unavailable", ErrInvalidArgument)
		default:
			return fmt.Errorf("%w: journal sensitivity is invalid", ErrInvalidArgument)
		}
	}
	for _, class := range o.Filter.Classes {
		switch class {
		case JournalClassState, JournalClassObservation, JournalClassEffect, JournalClassCheckpoint:
		default:
			return fmt.Errorf("%w: journal class is invalid", ErrInvalidArgument)
		}
	}
	for _, subject := range o.Filter.Subjects {
		if subject.Kind == nil && subject.ID == nil {
			return fmt.Errorf("%w: journal subject filters require kind or id", ErrInvalidArgument)
		}
	}
	if regex := o.Filter.Regex; regex != nil {
		if !utf8.ValidString(regex.Pattern) || len(regex.Pattern) < 1 || len(regex.Pattern) > 1024 {
			return fmt.Errorf("%w: journal regex must contain 1 to 1024 UTF-8 bytes", ErrInvalidArgument)
		}
		switch regex.Field {
		case "", JournalRegexFieldKind, JournalRegexFieldSubjects, JournalRegexFieldPayload,
			JournalRegexFieldRecord, JournalRegexFieldTerminalOutput:
		default:
			return fmt.Errorf("%w: journal regex field is invalid", ErrInvalidArgument)
		}
	}
	return nil
}

type SessionPingOptions struct{ ReadOptions }
type SessionShutdownOptions struct {
	MutationOptions
	Force *bool
}
type SessionReloadConfigOptions struct{ MutationOptions }
type SessionTerminalDefaultsUpdateOptions struct {
	MutationOptions
	Foreground          NullableString
	Background          NullableString
	Cursor              NullableString
	SelectionBackground NullableString
	SelectionForeground NullableString
	CursorStyle         NullableString
	CursorBlink         NullableBool
	Palette             NullableStringMap
	Complete            bool
}
type SessionWindowTitleSetOptions struct {
	MutationOptions
	Title string
}
type SessionWindowTitleClearOptions struct{ MutationOptions }

type ConnectedClientListOptions struct{ ReadOptions }
type ConnectedClientMetadataUpdateOptions struct {
	ControlOptions
	Name NullableString
	Kind NullableString
}
type ConnectedClientSizingSetOptions struct {
	ControlOptions
	Enabled   bool
	Exclusive *bool
}
type ConnectedClientSizingReleaseOptions struct{ ControlOptions }
type ConnectedClientCellPixelsSetOptions struct {
	ControlOptions
	WidthPX  uint32
	HeightPX uint32
}
type ConnectedClientDetachOptions struct{ ControlOptions }

type PairingDecision string

const (
	PairingAccept PairingDecision = "accept"
	PairingReject PairingDecision = "reject"
)

type PairingRequestListOptions struct{ ReadOptions }
type PairingRequestResolveOptions struct {
	MutationOptions
	Decision PairingDecision
}
type FrontendProjectionGetOptions struct {
	ReadOptions
	Projection Selector[ProjectionID]
}
type FrontendProjectionPutOptions struct {
	MutationOptions
	FrontendID                 string
	WindowID                   string
	Generation                 string
	Projection                 JSONValue
	ExpectedProjectionRevision *Decimal
}

type WorkspaceListOptions struct{ ReadOptions }
type WorkspaceCreateOptions struct {
	MutationOptions
	Name           *string
	InitialContent string
}
type WorkspaceRenameOptions struct {
	MutationOptions
	Name string
}
type WorkspaceMoveOptions struct {
	MutationOptions
	Index uint32
}
type WorkspaceFocusOptions struct{ MutationOptions }
type WorkspaceCloseOptions struct{ MutationOptions }
type WorkspaceRunOptions struct {
	MutationOptions
	Command Command
	CWD     *string
	Name    *string
	Cols    *uint16
	Rows    *uint16
}
type WorkspaceLayoutApplyOptions struct {
	MutationOptions
	Layout LayoutDocument
}

type ScreenListOptions struct{ ReadOptions }
type ScreenCreateOptions struct {
	MutationOptions
	Name *string
}
type ScreenRenameOptions struct {
	MutationOptions
	Name *string
}
type ScreenFocusOptions struct{ MutationOptions }
type ScreenCloseOptions struct{ MutationOptions }
type ScreenLayoutExportOptions struct{ ReadOptions }
type ScreenLayoutUndoOptions struct {
	MutationOptions
	ConfirmClose      bool
	ConfirmationToken *string
}

type PaneListOptions struct{ ReadOptions }
type PaneCreateOptions struct {
	MutationOptions
	CWD  *string
	Cols *uint16
	Rows *uint16
}
type PaneSplitOptions struct {
	MutationOptions
	Direction     Direction
	Ratio         *float64
	ViewportWidth *float64
	CWD           *string
	Cols          *uint16
	Rows          *uint16
}
type PaneRenameOptions struct {
	MutationOptions
	Name *string
}
type PaneFocusOptions struct{ MutationOptions }
type PaneFocusDirectionOptions struct {
	MutationOptions
	Direction Direction
}
type PaneNeighborGetOptions struct {
	ReadOptions
	Direction Direction
}
type PaneSwapOptions struct {
	MutationOptions
	OtherWorkspace Selector[WorkspaceID]
	OtherScreen    Selector[ScreenID]
	OtherPane      Selector[PaneID]
}
type PaneZoomOptions struct {
	MutationOptions
	Enabled *bool
}
type PaneSplitRatioSetOptions struct {
	MutationOptions
	SplitID SplitID
	Ratio   float64
}
type PaneViewportWidthSetOptions struct {
	MutationOptions
	Columns uint16
}
type PaneCloseOptions struct{ MutationOptions }
type PaneRunOptions struct {
	MutationOptions
	Command Command
	CWD     *string
	Name    *string
	Cols    *uint16
	Rows    *uint16
}

type TabListOptions struct{ ReadOptions }
type TabCreateTerminalOptions struct {
	MutationOptions
	Name *string
	CWD  *string
	Cols *uint16
	Rows *uint16
}
type TabCreateBrowserOptions struct {
	MutationOptions
	Name     *string
	URL      string
	WidthPX  *uint32
	HeightPX *uint32
}
type TabRenameOptions struct {
	MutationOptions
	Name *string
}
type TabMoveOptions struct {
	MutationOptions
	DestinationWorkspace Selector[WorkspaceID]
	DestinationScreen    Selector[ScreenID]
	DestinationPane      Selector[PaneID]
	Index                uint32
}
type TabFocusOptions struct{ MutationOptions }
type TabCloseOptions struct{ MutationOptions }

type TerminalListOptions struct{ ReadOptions }
type TerminalInputWriteOptions struct {
	MutationOptions
	Text  *string
	Bytes []byte
}
type TerminalInputKeysOptions struct {
	MutationOptions
	Keys []string
}
type TerminalInputMouseOptions struct {
	MutationOptions
	Kind      string
	Row       uint16
	Column    uint16
	Button    *string
	DeltaRows *int32
	Modifiers []string
}
type TerminalInputFocusOptions struct {
	MutationOptions
	Focused bool
}
type TerminalScreenReadOptions struct{ ReadOptions }
type TerminalStateReadOptions struct{ ReadOptions }
type TerminalHistoryReadOptions struct {
	ReadOptions
	Before *Decimal
	Limit  *uint32
	Styled *bool
}
type TerminalHistoryClearOptions struct{ MutationOptions }
type TerminalWaitOptions struct {
	ReadOptions
	Pattern   string
	TimeoutMS *Decimal
}
type TerminalWaitExitOptions struct {
	ReadOptions
	TimeoutMS *Decimal
}
type TerminalCopyOptions struct {
	ReadOptions
	Mode *TerminalCopyMode
}
type TerminalProcessGetOptions struct{ ReadOptions }
type TerminalRendererGrantCreateOptions struct {
	ControlOptions
	TTLMS *uint32
}
type TerminalViewerResizeOptions struct {
	ControlOptions
	AttachmentLease string
	Cols            uint16
	Rows            uint16
}
type TerminalViewerReleaseOptions struct {
	ControlOptions
	AttachmentLease string
}
type TerminalViewportScrollOptions struct {
	MutationOptions
	DeltaRows int32
}
type TerminalMoveOptions struct {
	MutationOptions
	DestinationWorkspace Selector[WorkspaceID]
	DestinationScreen    Selector[ScreenID]
	DestinationPane      Selector[PaneID]
	Index                uint32
}
type TerminalProjectOptions struct {
	MutationOptions
	DestinationWorkspace Selector[WorkspaceID]
	DestinationScreen    Selector[ScreenID]
	DestinationPane      Selector[PaneID]
	Index                uint32
	Name                 *string
}
type TerminalAttachOptions struct {
	StreamOptions
	Cols     *uint16
	Rows     *uint16
	ReadOnly *bool
}
type TerminalCloseOptions struct{ MutationOptions }

type BrowserListOptions struct{ ReadOptions }
type BrowserNavigateOptions struct {
	MutationOptions
	URL string
}
type BrowserBackOptions struct{ MutationOptions }
type BrowserForwardOptions struct{ MutationOptions }
type BrowserReloadOptions struct{ MutationOptions }
type BrowserActivateOptions struct{ MutationOptions }
type BrowserInputKeyOptions struct {
	MutationOptions
	Key       string
	Kind      *string
	Modifiers []string
}
type BrowserInputTextOptions struct {
	MutationOptions
	Text string
}
type BrowserInputMouseOptions struct {
	MutationOptions
	Kind            string
	XPX             float64
	YPX             float64
	Button          *string
	ClickCount      *uint32
	PointerFrameSeq Decimal
}
type BrowserInputWheelOptions struct {
	MutationOptions
	DeltaX          float64
	DeltaY          float64
	XPX             float64
	YPX             float64
	PointerFrameSeq Decimal
}
type BrowserViewerResizeOptions struct {
	ControlOptions
	AttachmentLease string
	WidthPX         uint32
	HeightPX        uint32
}
type BrowserViewerReleaseOptions struct {
	ControlOptions
	AttachmentLease string
}
type BrowserAttachOptions struct {
	StreamOptions
	WidthPX  *uint32
	HeightPX *uint32
}
type BrowserCloseOptions struct{ MutationOptions }

type NotificationListOptions struct {
	ReadOptions
	Limit *uint32
}
type NotificationCreateOptions struct {
	MutationOptions
	Title      string
	Body       string
	Level      *string
	TerminalID *TerminalID
}
type AgentListOptions struct {
	ReadOptions
	TerminalID *TerminalID
	State      *AgentState
}
type AgentReportOptions struct {
	MutationOptions
	TerminalID    TerminalID
	State         AgentState
	Source        AgentReportSource
	SourceSession *string
}

type SidebarViewGetOptions struct{ ReadOptions }
type SidebarViewEnsureOptions struct {
	MutationOptions
	Cols     uint16
	Rows     uint16
	Relaunch *bool
}
type SidebarViewAttachOptions struct{ StreamOptions }
type SidebarViewInputOptions struct {
	MutationOptions
	Data []byte
}
type SidebarViewResizeOptions struct {
	MutationOptions
	Cols uint16
	Rows uint16
}
type SidebarViewReloadOptions struct{ MutationOptions }
