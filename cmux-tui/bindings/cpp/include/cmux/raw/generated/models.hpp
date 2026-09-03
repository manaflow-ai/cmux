#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

#include "cmux/raw/codec.hpp"

namespace cmux::raw {

inline constexpr std::uint32_t kMuxProtocolVersion = 12U;
inline constexpr std::string_view kProtocolIrSha256 = "3abe68cfbb73abb8aab5265d34cdafd7207a111cbe9e1923c8637f5376abb929";

struct AgentRecord;
enum class AgentReportSource;
enum class AgentSource;
enum class AgentState;
struct AppliedPane;
struct ApplyLayoutResult;
struct AttachedViewOutcomeResult;
struct AttachedViewResizeResult;
struct Base64;
struct BrowserFrame;
enum class BrowserProviderAuthentication;
struct BrowserProviderSnapshot;
struct BrowserProviderTarget;
struct BrowserProviderUnregisterResult;
struct CellPixelFailure;
struct CellPixelResize;
struct CellPixelSurface;
struct ClientInfo;
struct ClientSize;
enum class ClientTransport;
struct CloseTerminalResult;
struct ColorHex;
struct CopyResult;
enum class CursorStyle;
struct DeadPane;
struct DeclarativeLayout;
struct EmptyResult;
struct ExportLayoutResult;
struct ExportedPane;
struct FocusDirectionResult;
enum class FrontendFocusTarget;
struct FrontendJournalEvent;
struct FrontendProjection;
struct GetCellPixelsResult;
struct Id;
struct IdMapping;
struct IdentifyResult;
struct IdsResult;
struct JsonValue;
struct KittyGraphicsState;
struct KittyImageAlias;
struct Layout;
struct LayoutUndoConfirmationRequired;
struct LayoutUndoResult;
struct LayoutUndoUndone;
struct ListAgentsResult;
struct ListTerminalsResult;
struct LivePane;
struct MachineUsage;
struct MachineUsageResult;
struct MintTerminalRendererResult;
struct MoveTerminalResult;
enum class NotificationLevel;
struct NotificationMarker;
struct NotifyResult;
struct Pane;
enum class PaneDirection;
struct PaneNeighborResult;
struct PingResult;
struct ProcessInfoResult;
struct ProviderWorkspaceMutationResult;
struct ReadScreenResult;
struct ReadScrollbackResult;
struct RenderCursor;
enum class RenderGraphicFormat;
struct RenderGraphicImage;
struct RenderGraphicPlacement;
struct RenderGraphics;
struct RenderGraphicsDelta;
struct RenderRow;
struct RenderRun;
enum class RenderUnderline;
struct ReportAgentResult;
struct ResizeSurfaceResult;
struct ResolveTerminalResult;
struct ResourceSelectors;
struct RunResult;
struct Screen;
struct SetCellPixelsResult;
struct ShutdownDaemonResult;
struct SidebarPluginResult;
struct Size;
enum class SplitDirection;
struct SurfaceResult;
struct Tab;
struct TerminalColors;
struct TerminalEventsResult;
struct TerminalExit;
struct TerminalExitOutcome;
enum class TerminalKey;
enum class TerminalKeyAction;
struct TerminalKeyInput;
enum class TerminalLifecycle;
struct TerminalModifiers;
struct TerminalPlacement;
struct TerminalRecord;
struct TerminalRegistryEvent;
struct Tree;
enum class ViewAttachmentOutcome;
struct VtStateResult;
struct WaitForResult;
struct Workspace;
struct WorkspaceMutationResult;
struct ZoomPaneResult;
struct ApplyLayoutRequest;
struct AttachSurfaceRequest;
struct BrowserActivateRequest;
struct BrowserBackRequest;
struct BrowserForwardRequest;
struct BrowserFramePresentedRequest;
struct BrowserInsertTextRequest;
struct BrowserKeyRequest;
struct BrowserKeyPressRequest;
struct BrowserMouseRequest;
struct BrowserMouseGuardedRequest;
struct BrowserNavigateRequest;
struct BrowserReloadRequest;
struct BrowserWheelRequest;
struct BrowserWheelGuardedRequest;
struct ClearHistoryRequest;
struct ClearWindowTitleRequest;
struct ClientFocusRequest;
struct ClientFocusResult;
struct ClosePaneRequest;
struct CloseProviderManagedWorkspaceRequest;
struct CloseScreenRequest;
struct CloseSurfaceRequest;
struct CloseTerminalRequest;
struct CloseWorkspaceRequest;
struct CopyRequest;
struct CreateSurfaceWithReceiptRequest;
struct CreateTerminalRequest;
struct CreateWorkspaceRequest;
struct DetachAttachedViewRequest;
struct DetachClientRequest;
struct ExportLayoutRequest;
struct FocusDirectionRequest;
struct FocusPaneRequest;
struct GetBrowserProviderRequest;
struct GetCellPixelsRequest;
struct GetFrontendProjectionRequest;
struct IdentifyRequest;
struct IdsRequest;
struct JournalFrontendEventRequest;
struct JournalFrontendEventResult;
struct ListAgentsRequest;
struct ListClientsRequest;
struct ListClientsResult;
struct ListTerminalsRequest;
struct ListWorkspacesRequest;
struct MachineUsageRequest;
struct MarkWorkspacesProviderManagedRequest;
struct MintTerminalRendererRequest;
struct MintTerminalRendererByTerminalRequest;
struct MoveTabRequest;
struct MoveTerminalRequest;
struct MoveWorkspaceRequest;
struct NewBrowserTabRequest;
struct NewPaneRequest;
struct NewPaneRightRequest;
struct NewScreenRequest;
struct NewTabRequest;
struct NewWorkspaceRequest;
struct NotifyRequest;
struct PairingResponseRequest;
struct PaneNeighborRequest;
struct PingRequest;
struct ProcessInfoRequest;
struct PutFrontendProjectionRequest;
struct ReadScreenRequest;
struct ReadScrollbackRequest;
struct RegisterBrowserProviderRequest;
struct ReleaseAttachedViewSizeRequest;
struct ReleaseSurfaceSizeRequest;
struct ReloadConfigRequest;
struct ReloadConfigResult;
struct RenamePaneRequest;
struct RenameProviderManagedWorkspaceRequest;
struct RenameScreenRequest;
struct RenameSurfaceRequest;
struct RenameWorkspaceRequest;
struct ReportAgentRequest;
struct ReportFocusRequest;
struct ResizeAttachedViewRequest;
struct ResizeSurfaceRequest;
struct ResolveTerminalRequest;
struct RunRequest;
struct ScrollSurfaceRequest;
struct SelectScreenRequest;
struct SelectTabRequest;
struct SelectWorkspaceRequest;
struct SendRequest;
struct SendKeyRequest;
struct SetCellPixelsRequest;
struct SetClientInfoRequest;
struct SetClientSizingRequest;
struct SetDefaultColorsRequest;
struct SetRatioRequest;
struct SetSplitRatioRequest;
struct SetViewportPaneWidthRequest;
struct SetWindowTitleRequest;
struct ShutdownDaemonRequest;
struct SidebarPluginRequest;
struct SplitRequest;
struct SubscribeRequest;
struct SwapPaneRequest;
struct TerminalEventsRequest;
struct UndoLayoutRequest;
struct UnregisterBrowserProviderRequest;
struct VtStateRequest;
struct WaitForRequest;
struct ZoomPaneRequest;
struct AgentChangedEvent;
struct BellEvent;
struct BrowserStateEvent;
struct ClientAttachedEvent;
struct ClientChangedEvent;
struct ClientDetachedEvent;
struct ClientListInvalidatedEvent;
struct ColorsChangedEvent;
struct ConfigReloadRequestedEvent;
struct DetachedEvent;
struct EmptyEvent;
struct FrameEvent;
struct FrontendProjectionChangedEvent;
struct GraphicsStatusEvent;
struct LayoutChangedEvent;
struct MachineUsageChangedEvent;
struct NotificationEvent;
struct OutputEvent;
struct OverflowEvent;
struct PairingRequestedEvent;
struct PairingResolvedEvent;
struct PaneAddedEvent;
struct PaneClosedEvent;
struct RenderDeltaEvent;
struct RenderStateEvent;
struct ResizedEvent;
struct ScreenAddedEvent;
struct ScreenClosedEvent;
struct ScreenRenamedEvent;
struct ScrollChangedEvent;
struct StatusEvent;
struct SurfaceExitedEvent;
struct SurfaceOutputEvent;
struct SurfaceResizeFailedEvent;
struct SurfaceResizedEvent;
struct TabAddedEvent;
struct TabClosedEvent;
struct TabRenamedEvent;
struct TerminalRegistryChangedEvent;
struct TitleChangedEvent;
struct TreeChangedEvent;
struct VtStateEvent;
struct WindowTitleRequestedEvent;
struct WorkspaceAddedEvent;
struct WorkspaceClosedEvent;
struct WorkspaceMovedEvent;
struct WorkspaceRenamedEvent;
enum class CopyResultMode;
struct DeclarativeLayoutLeaf;
struct DeclarativeLayoutSplit;
struct DeclarativeLayoutStack;
struct FrontendJournalEventFocus;
struct FrontendJournalEventResize;
struct FrontendJournalEventViewport;
enum class IdMappingKind;
struct LayoutLeaf;
struct LayoutSplit;
struct LayoutStack;
enum class TabBrowserSource;
enum class TabBrowserStatus;
enum class TabKind;
struct TerminalExitOutcomeExit;
struct TerminalExitOutcomeSignal;
struct TerminalExitOutcomeUnknown;
enum class AttachSurfaceRequestMode;
enum class BrowserKeyRequestKind;
enum class BrowserMouseRequestKind;
enum class BrowserMouseGuardedRequestKind;
enum class CopyRequestMode;
enum class IdsRequestKind;
enum class SubscribeRequestTreeEvents;
enum class ZoomPaneRequestMode;
enum class BrowserStateEventStatus;
enum class ClientAttachedEventTransport;
enum class GraphicsStatusEventKind;

enum class AgentSource {
    detected,
    socket,
    hook,
};

enum class AgentState {
    working,
    blocked,
    idle,
    done,
    unknown,
};

struct Id {
    std::uint64_t value{};
    friend bool operator==(const Id&, const Id&) = default;
};

struct AgentChangedEvent {
    std::optional<std::string> session{};
    AgentSource source{};
    AgentState state{};
    Id surface{};
    std::uint64_t updated_at_ms{};
    friend bool operator==(const AgentChangedEvent&, const AgentChangedEvent&) = default;
};

struct AgentRecord {
    std::optional<std::string> session{};
    AgentSource source{};
    AgentState state{};
    Id surface{};
    std::uint64_t updated_at_ms{};
    friend bool operator==(const AgentRecord&, const AgentRecord&) = default;
};

enum class AgentReportSource {
    socket,
    hook,
};

struct AppliedPane {
    Id pane{};
    Id surface{};
    friend bool operator==(const AppliedPane&, const AppliedPane&) = default;
};

struct DeclarativeLayoutLeaf {
    Field<std::vector<std::string>> command{};
    Field<std::string> cwd{};
    friend bool operator==(const DeclarativeLayoutLeaf&, const DeclarativeLayoutLeaf&) = default;
};

enum class SplitDirection {
    right,
    down,
};

struct DeclarativeLayoutStack {
    Id expanded{};
    std::vector<Id> panes{};
    friend bool operator==(const DeclarativeLayoutStack&, const DeclarativeLayoutStack&) = default;
};

struct DeclarativeLayoutSplit {
    std::shared_ptr<DeclarativeLayout> a{};
    std::shared_ptr<DeclarativeLayout> b{};
    SplitDirection dir{};
    float ratio{};
    friend bool operator==(const DeclarativeLayoutSplit&, const DeclarativeLayoutSplit&) = default;
};

struct DeclarativeLayout {
    using Variant = std::variant<DeclarativeLayoutLeaf, DeclarativeLayoutSplit, DeclarativeLayoutStack>;
    Variant value{};
    friend bool operator==(const DeclarativeLayout&, const DeclarativeLayout&) = default;
};

struct ApplyLayoutRequest {
    Field<std::uint16_t> cols{};
    DeclarativeLayout layout{};
    Field<std::string> name{};
    Field<std::uint16_t> rows{};
    Field<Id> workspace{};
    friend bool operator==(const ApplyLayoutRequest&, const ApplyLayoutRequest&) = default;
};

struct ApplyLayoutResult {
    std::vector<AppliedPane> panes{};
    Id screen{};
    friend bool operator==(const ApplyLayoutResult&, const ApplyLayoutResult&) = default;
};

enum class AttachSurfaceRequestMode {
    bytes,
    render,
};

struct AttachSurfaceRequest {
    Field<std::uint16_t> cols{};
    Field<AttachSurfaceRequestMode> mode{};
    Field<std::uint16_t> rows{};
    Id surface{};
    friend bool operator==(const AttachSurfaceRequest&, const AttachSurfaceRequest&) = default;
};

enum class ViewAttachmentOutcome {
    applied,
    passive,
    superseded,
};

struct AttachedViewOutcomeResult {
    ViewAttachmentOutcome outcome{};
    friend bool operator==(const AttachedViewOutcomeResult&, const AttachedViewOutcomeResult&) = default;
};

struct AttachedViewResizeResult {
    bool accepted{};
    ViewAttachmentOutcome outcome{};
    std::optional<std::uint64_t> reservation_id{};
    friend bool operator==(const AttachedViewResizeResult&, const AttachedViewResizeResult&) = default;
};

struct Base64 {
    std::string value{};
    friend bool operator==(const Base64&, const Base64&) = default;
};

struct BellEvent {
    Id surface{};
    friend bool operator==(const BellEvent&, const BellEvent&) = default;
};

struct BrowserActivateRequest {
    Id surface{};
    friend bool operator==(const BrowserActivateRequest&, const BrowserActivateRequest&) = default;
};

struct BrowserBackRequest {
    Id surface{};
    friend bool operator==(const BrowserBackRequest&, const BrowserBackRequest&) = default;
};

struct BrowserForwardRequest {
    Id surface{};
    friend bool operator==(const BrowserForwardRequest&, const BrowserForwardRequest&) = default;
};

struct BrowserFrame {
    Base64 data{};
    std::uint32_t height{};
    std::uint64_t seq{};
    std::uint32_t width{};
    friend bool operator==(const BrowserFrame&, const BrowserFrame&) = default;
};

struct BrowserFramePresentedRequest {
    std::uint64_t frame_seq{};
    Id surface{};
    friend bool operator==(const BrowserFramePresentedRequest&, const BrowserFramePresentedRequest&) = default;
};

struct BrowserInsertTextRequest {
    Id surface{};
    std::string text{};
    friend bool operator==(const BrowserInsertTextRequest&, const BrowserInsertTextRequest&) = default;
};

struct BrowserKeyPressRequest {
    std::string code{};
    std::string key{};
    std::uint32_t modifiers{};
    Id surface{};
    Field<std::string> text{};
    std::uint32_t windows_virtual_key_code{};
    friend bool operator==(const BrowserKeyPressRequest&, const BrowserKeyPressRequest&) = default;
};

enum class BrowserKeyRequestKind {
    down,
    up,
};

struct BrowserKeyRequest {
    std::string code{};
    std::string key{};
    BrowserKeyRequestKind kind{};
    std::uint32_t modifiers{};
    Id surface{};
    Field<std::string> text{};
    std::uint32_t windows_virtual_key_code{};
    friend bool operator==(const BrowserKeyRequest&, const BrowserKeyRequest&) = default;
};

enum class BrowserMouseGuardedRequestKind {
    down,
    up,
    move,
};

struct BrowserMouseGuardedRequest {
    Field<std::string> button{};
    Field<std::uint32_t> click_count{};
    std::uint64_t frame_seq{};
    BrowserMouseGuardedRequestKind kind{};
    Id surface{};
    double x_px{};
    double y_px{};
    friend bool operator==(const BrowserMouseGuardedRequest&, const BrowserMouseGuardedRequest&) = default;
};

enum class BrowserMouseRequestKind {
    down,
    up,
    move,
};

struct BrowserMouseRequest {
    Field<std::string> button{};
    Field<std::uint32_t> click_count{};
    Field<std::uint64_t> frame_seq{};
    BrowserMouseRequestKind kind{};
    Id surface{};
    double x_px{};
    double y_px{};
    friend bool operator==(const BrowserMouseRequest&, const BrowserMouseRequest&) = default;
};

struct BrowserNavigateRequest {
    Id surface{};
    std::string url{};
    friend bool operator==(const BrowserNavigateRequest&, const BrowserNavigateRequest&) = default;
};

enum class BrowserProviderAuthentication {
    none,
    bearer,
};

struct BrowserProviderTarget {
    std::string tab_id{};
    std::string target_id{};
    friend bool operator==(const BrowserProviderTarget&, const BrowserProviderTarget&) = default;
};

struct BrowserProviderSnapshot {
    std::optional<BrowserProviderAuthentication> authentication{};
    bool available{};
    std::optional<std::uint64_t> clients{};
    std::optional<std::string> endpoint{};
    std::optional<std::string> provider_id{};
    std::uint64_t revision{};
    std::vector<BrowserProviderTarget> targets{};
    friend bool operator==(const BrowserProviderSnapshot&, const BrowserProviderSnapshot&) = default;
};

struct BrowserProviderUnregisterResult {
    bool removed{};
    friend bool operator==(const BrowserProviderUnregisterResult&, const BrowserProviderUnregisterResult&) = default;
};

struct BrowserReloadRequest {
    Id surface{};
    friend bool operator==(const BrowserReloadRequest&, const BrowserReloadRequest&) = default;
};

enum class BrowserStateEventStatus {
    starting,
    live,
    failed,
};

struct BrowserStateEvent {
    std::uint16_t cols{};
    std::optional<std::string> error{};
    Field<BrowserFrame> frame{};
    bool frames_stalled{};
    std::uint16_t rows{};
    BrowserStateEventStatus status{};
    Id surface{};
    std::string title{};
    std::string url{};
    friend bool operator==(const BrowserStateEvent&, const BrowserStateEvent&) = default;
};

struct BrowserWheelGuardedRequest {
    double delta_y_px{};
    std::uint64_t frame_seq{};
    Id surface{};
    double x_px{};
    double y_px{};
    friend bool operator==(const BrowserWheelGuardedRequest&, const BrowserWheelGuardedRequest&) = default;
};

struct BrowserWheelRequest {
    double delta_y_px{};
    Field<std::uint64_t> frame_seq{};
    Id surface{};
    double x_px{};
    double y_px{};
    friend bool operator==(const BrowserWheelRequest&, const BrowserWheelRequest&) = default;
};

struct CellPixelFailure {
    std::string error{};
    Id surface{};
    friend bool operator==(const CellPixelFailure&, const CellPixelFailure&) = default;
};

struct CellPixelResize {
    std::uint16_t cols{};
    std::uint64_t reservation_id{};
    std::uint16_t rows{};
    Id surface{};
    friend bool operator==(const CellPixelResize&, const CellPixelResize&) = default;
};

struct CellPixelSurface {
    std::uint16_t height_px{};
    Id surface{};
    std::uint16_t width_px{};
    friend bool operator==(const CellPixelSurface&, const CellPixelSurface&) = default;
};

enum class TerminalKey {
    unidentified,
    backquote,
    backslash,
    bracket_left,
    bracket_right,
    comma,
    digit0,
    digit1,
    digit2,
    digit3,
    digit4,
    digit5,
    digit6,
    digit7,
    digit8,
    digit9,
    equal,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    minus,
    period,
    quote,
    semicolon,
    slash,
    backspace,
    enter,
    space,
    tab,
    delete_,
    end,
    home,
    insert,
    page_down,
    page_up,
    arrow_down,
    arrow_left,
    arrow_right,
    arrow_up,
    numpad0,
    numpad1,
    numpad2,
    numpad3,
    numpad4,
    numpad5,
    numpad6,
    numpad7,
    numpad8,
    numpad9,
    numpad_add,
    numpad_backspace,
    numpad_comma,
    numpad_decimal,
    numpad_divide,
    numpad_enter,
    numpad_equal,
    numpad_multiply,
    numpad_subtract,
    numpad_up,
    numpad_down,
    numpad_right,
    numpad_left,
    numpad_begin,
    numpad_home,
    numpad_end,
    numpad_insert,
    numpad_delete,
    numpad_page_up,
    numpad_page_down,
    escape,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
};

enum class TerminalKeyAction {
    press,
    release,
    repeat,
};

struct TerminalModifiers {
    bool alt{};
    bool caps_lock{};
    bool control{};
    bool num_lock{};
    bool shift{};
    bool super{};
    friend bool operator==(const TerminalModifiers&, const TerminalModifiers&) = default;
};

struct TerminalKeyInput {
    Field<TerminalKeyAction> action{};
    Field<std::string> base_layout_codepoint{};
    std::optional<bool> composing{};
    TerminalModifiers consumed_mods{};
    TerminalKey key{};
    bool macos_option_as_alt{};
    TerminalModifiers mods{};
    Field<std::string> shifted_codepoint{};
    Field<std::string> unshifted_codepoint{};
    std::string utf8{};
    friend bool operator==(const TerminalKeyInput&, const TerminalKeyInput&) = default;
};

struct ClearHistoryRequest {
    Field<TerminalKeyInput> fallback_key{};
    Id surface{};
    friend bool operator==(const ClearHistoryRequest&, const ClearHistoryRequest&) = default;
};

struct ClearWindowTitleRequest {
    friend bool operator==(const ClearWindowTitleRequest&, const ClearWindowTitleRequest&) = default;
};

enum class ClientAttachedEventTransport {
    unix_,
    ws,
};

struct ClientAttachedEvent {
    std::uint64_t client{};
    std::optional<std::string> kind{};
    std::optional<std::string> name{};
    ClientAttachedEventTransport transport{};
    friend bool operator==(const ClientAttachedEvent&, const ClientAttachedEvent&) = default;
};

struct ClientChangedEvent {
    std::uint64_t client{};
    std::optional<std::string> kind{};
    std::optional<std::string> name{};
    friend bool operator==(const ClientChangedEvent&, const ClientChangedEvent&) = default;
};

struct ClientDetachedEvent {
    std::uint64_t client{};
    friend bool operator==(const ClientDetachedEvent&, const ClientDetachedEvent&) = default;
};

struct ClientFocusRequest {
    std::string client_id{};
    friend bool operator==(const ClientFocusRequest&, const ClientFocusRequest&) = default;
};

struct ClientFocusResult {
    std::optional<Id> pane{};
    std::optional<std::uint64_t> tab{};
    friend bool operator==(const ClientFocusResult&, const ClientFocusResult&) = default;
};

struct ClientSize {
    std::optional<std::uint16_t> cols{};
    std::optional<std::uint16_t> rows{};
    bool size_participating{};
    Id surface{};
    friend bool operator==(const ClientSize&, const ClientSize&) = default;
};

enum class ClientTransport {
    local,
    unix_,
    ws,
};

struct ClientInfo {
    std::vector<Id> attached{};
    std::uint64_t client{};
    std::uint64_t connected_seconds{};
    std::optional<std::string> kind{};
    std::optional<std::string> name{};
    bool self{};
    std::vector<ClientSize> sizes{};
    ClientTransport transport{};
    friend bool operator==(const ClientInfo&, const ClientInfo&) = default;
};

struct ClientListInvalidatedEvent {
    friend bool operator==(const ClientListInvalidatedEvent&, const ClientListInvalidatedEvent&) = default;
};

struct ClosePaneRequest {
    Id pane{};
    friend bool operator==(const ClosePaneRequest&, const ClosePaneRequest&) = default;
};

struct CloseProviderManagedWorkspaceRequest {
    std::string authority{};
    std::string key{};
    Id workspace{};
    friend bool operator==(const CloseProviderManagedWorkspaceRequest&, const CloseProviderManagedWorkspaceRequest&) = default;
};

struct CloseScreenRequest {
    Id screen{};
    friend bool operator==(const CloseScreenRequest&, const CloseScreenRequest&) = default;
};

struct CloseSurfaceRequest {
    Id surface{};
    friend bool operator==(const CloseSurfaceRequest&, const CloseSurfaceRequest&) = default;
};

struct CloseTerminalRequest {
    Field<std::string> expected_generation{};
    Field<std::uint64_t> expected_revision{};
    Field<std::string> mutation_id{};
    Field<std::string> origin{};
    std::string terminal_id{};
    Field<std::string> terminal_incarnation{};
    friend bool operator==(const CloseTerminalRequest&, const CloseTerminalRequest&) = default;
};

struct CloseTerminalResult {
    bool already_closed{};
    std::string generation{};
    std::string registry_id{};
    std::optional<Id> surface{};
    std::string terminal_id{};
    std::optional<std::string> terminal_incarnation{};
    std::uint64_t terminal_revision{};
    friend bool operator==(const CloseTerminalResult&, const CloseTerminalResult&) = default;
};

struct CloseWorkspaceRequest {
    Field<std::string> expected_generation{};
    Field<std::uint64_t> expected_revision{};
    Field<std::string> key{};
    Field<std::string> mutation_id{};
    Field<std::string> origin{};
    Field<Id> workspace{};
    friend bool operator==(const CloseWorkspaceRequest&, const CloseWorkspaceRequest&) = default;
};

struct ColorHex {
    std::string value{};
    friend bool operator==(const ColorHex&, const ColorHex&) = default;
};

enum class CursorStyle {
    block,
    underline,
    bar,
};

struct ColorsChangedEvent {
    std::optional<ColorHex> bg{};
    Field<ColorHex> cursor{};
    Field<bool> cursor_blink{};
    Field<CursorStyle> cursor_style{};
    std::optional<ColorHex> fg{};
    std::optional<std::map<std::string, ColorHex, std::less<>>> palette{};
    std::optional<ColorHex> selection_bg{};
    std::optional<ColorHex> selection_fg{};
    std::optional<Id> surface{};
    friend bool operator==(const ColorsChangedEvent&, const ColorsChangedEvent&) = default;
};

struct ConfigReloadRequestedEvent {
    friend bool operator==(const ConfigReloadRequestedEvent&, const ConfigReloadRequestedEvent&) = default;
};

enum class CopyRequestMode {
    screen,
    selection,
    scrollback,
};

struct CopyRequest {
    CopyRequestMode mode{};
    Id surface{};
    friend bool operator==(const CopyRequest&, const CopyRequest&) = default;
};

enum class CopyResultMode {
    screen,
    selection,
    scrollback,
};

struct CopyResult {
    CopyResultMode mode{};
    std::string text{};
    friend bool operator==(const CopyResult&, const CopyResult&) = default;
};

struct ResourceSelectors {
    Field<std::string> agent{};
    Field<std::string> browser{};
    Field<std::string> client{};
    Field<std::string> frontend_projection{};
    Field<std::string> machine{};
    Field<std::string> notification{};
    Field<std::string> pairing_request{};
    Field<std::string> pane{};
    Field<std::string> screen{};
    Field<std::string> session{};
    Field<std::string> sidebar_view{};
    Field<std::string> split{};
    Field<std::string> stream{};
    Field<std::string> tab{};
    Field<std::string> terminal{};
    Field<std::string> workspace{};
    friend bool operator==(const ResourceSelectors&, const ResourceSelectors&) = default;
};

struct CreateSurfaceWithReceiptRequest {
    Field<std::vector<std::string>> argv{};
    Field<std::uint16_t> cols{};
    Field<std::string> cwd{};
    Field<std::string> idempotency_key{};
    std::string operation{};
    std::string origin{};
    Field<Id> pane{};
    std::string receipt{};
    Field<std::uint16_t> rows{};
    std::optional<std::vector<ResourceSelectors>> selector_fallbacks{};
    Field<ResourceSelectors> selectors{};
    Field<std::string> url{};
    Field<float> width{};
    Field<Id> workspace{};
    friend bool operator==(const CreateSurfaceWithReceiptRequest&, const CreateSurfaceWithReceiptRequest&) = default;
};

struct CreateTerminalRequest {
    Field<std::vector<std::string>> argv{};
    Field<std::uint16_t> cols{};
    Field<std::string> command{};
    Field<std::string> cwd{};
    Field<std::string> expected_generation{};
    Field<std::uint64_t> expected_revision{};
    Field<std::string> key{};
    Field<std::string> mutation_id{};
    Field<std::string> name{};
    Field<std::string> origin{};
    Field<std::uint16_t> rows{};
    Field<std::string> terminal_id{};
    Field<Id> workspace{};
    friend bool operator==(const CreateTerminalRequest&, const CreateTerminalRequest&) = default;
};

struct CreateWorkspaceRequest {
    Field<std::string> expected_generation{};
    Field<std::uint64_t> expected_revision{};
    Field<std::string> key{};
    Field<std::string> mutation_id{};
    Field<std::string> name{};
    Field<std::string> origin{};
    friend bool operator==(const CreateWorkspaceRequest&, const CreateWorkspaceRequest&) = default;
};

struct DeadPane {
    Id id{};
    friend bool operator==(const DeadPane&, const DeadPane&) = default;
};

struct DetachAttachedViewRequest {
    std::string lease{};
    Id surface{};
    friend bool operator==(const DetachAttachedViewRequest&, const DetachAttachedViewRequest&) = default;
};

struct DetachClientRequest {
    std::uint64_t client{};
    friend bool operator==(const DetachClientRequest&, const DetachClientRequest&) = default;
};

struct DetachedEvent {
    Id surface{};
    friend bool operator==(const DetachedEvent&, const DetachedEvent&) = default;
};

struct EmptyEvent {
    friend bool operator==(const EmptyEvent&, const EmptyEvent&) = default;
};

struct EmptyResult {
    friend bool operator==(const EmptyResult&, const EmptyResult&) = default;
};

struct ExportLayoutRequest {
    Field<Id> screen{};
    friend bool operator==(const ExportLayoutRequest&, const ExportLayoutRequest&) = default;
};

struct ExportedPane {
    Id pane{};
    std::vector<Id> surfaces{};
    friend bool operator==(const ExportedPane&, const ExportedPane&) = default;
};

struct LayoutLeaf {
    Id pane{};
    friend bool operator==(const LayoutLeaf&, const LayoutLeaf&) = default;
};

struct LayoutStack {
    Id expanded{};
    std::vector<Id> panes{};
    friend bool operator==(const LayoutStack&, const LayoutStack&) = default;
};

struct LayoutSplit {
    std::shared_ptr<Layout> a{};
    std::shared_ptr<Layout> b{};
    SplitDirection dir{};
    float ratio{};
    std::optional<Id> split{};
    friend bool operator==(const LayoutSplit&, const LayoutSplit&) = default;
};

struct Layout {
    using Variant = std::variant<LayoutLeaf, LayoutSplit, LayoutStack>;
    Variant value{};
    friend bool operator==(const Layout&, const Layout&) = default;
};

struct ExportLayoutResult {
    Layout layout{};
    std::vector<ExportedPane> panes{};
    friend bool operator==(const ExportLayoutResult&, const ExportLayoutResult&) = default;
};

enum class PaneDirection {
    left,
    right,
    up,
    down,
};

struct FocusDirectionRequest {
    PaneDirection dir{};
    Field<Id> pane{};
    friend bool operator==(const FocusDirectionRequest&, const FocusDirectionRequest&) = default;
};

struct FocusDirectionResult {
    Id pane{};
    friend bool operator==(const FocusDirectionResult&, const FocusDirectionResult&) = default;
};

struct FocusPaneRequest {
    Id pane{};
    friend bool operator==(const FocusPaneRequest&, const FocusPaneRequest&) = default;
};

struct FrameEvent {
    Base64 data{};
    std::uint32_t height{};
    std::uint64_t seq{};
    Id surface{};
    std::uint32_t width{};
    friend bool operator==(const FrameEvent&, const FrameEvent&) = default;
};

enum class FrontendFocusTarget {
    pane,
    machine_rail,
    workspace_rail,
    tabs_rail,
    projection_rail,
};

struct FrontendJournalEventFocus {
    Field<std::string> content_id{};
    std::string event_id{};
    std::string frontend_projection_id{};
    std::string generation{};
    Field<std::string> pane_id{};
    Field<std::string> screen_id{};
    Field<std::string> tab_id{};
    FrontendFocusTarget target{};
    Field<std::string> workspace_id{};
    friend bool operator==(const FrontendJournalEventFocus&, const FrontendJournalEventFocus&) = default;
};

struct FrontendJournalEventResize {
    std::uint16_t cell_height{};
    std::uint16_t cell_width{};
    std::uint16_t cols{};
    std::string event_id{};
    std::string frontend_projection_id{};
    std::string generation{};
    std::uint16_t rows{};
    friend bool operator==(const FrontendJournalEventResize&, const FrontendJournalEventResize&) = default;
};

struct FrontendJournalEventViewport {
    std::string event_id{};
    std::string frontend_projection_id{};
    std::string generation{};
    std::uint64_t offset{};
    Field<std::string> screen_id{};
    bool settled{};
    std::uint64_t target{};
    friend bool operator==(const FrontendJournalEventViewport&, const FrontendJournalEventViewport&) = default;
};

struct FrontendJournalEvent {
    using Variant = std::variant<FrontendJournalEventFocus, FrontendJournalEventResize, FrontendJournalEventViewport>;
    Variant value{};
    friend bool operator==(const FrontendJournalEvent&, const FrontendJournalEvent&) = default;
};

struct JsonValue {
    Json value{};
    friend bool operator==(const JsonValue&, const JsonValue&) = default;
};

struct FrontendProjection {
    std::string frontend{};
    std::optional<JsonValue> projection{};
    std::uint64_t projection_revision{};
    std::optional<bool> replayed{};
    std::uint32_t schema_version{};
    std::string scope{};
    std::string subject_key{};
    friend bool operator==(const FrontendProjection&, const FrontendProjection&) = default;
};

struct FrontendProjectionChangedEvent {
    std::string frontend{};
    std::string mutation_id{};
    std::string origin{};
    std::uint64_t projection_revision{};
    std::string scope{};
    std::string subject_key{};
    friend bool operator==(const FrontendProjectionChangedEvent&, const FrontendProjectionChangedEvent&) = default;
};

struct GetBrowserProviderRequest {
    friend bool operator==(const GetBrowserProviderRequest&, const GetBrowserProviderRequest&) = default;
};

struct GetCellPixelsRequest {
    friend bool operator==(const GetCellPixelsRequest&, const GetCellPixelsRequest&) = default;
};

struct GetCellPixelsResult {
    std::uint16_t height_px{};
    std::vector<CellPixelSurface> surfaces{};
    std::uint16_t width_px{};
    friend bool operator==(const GetCellPixelsResult&, const GetCellPixelsResult&) = default;
};

struct GetFrontendProjectionRequest {
    std::string frontend{};
    std::string scope{};
    std::string subject_key{};
    friend bool operator==(const GetFrontendProjectionRequest&, const GetFrontendProjectionRequest&) = default;
};

enum class GraphicsStatusEventKind {
    kitty_image_budget_worker_start_failed,
    kitty_image_budget_update_failed,
    cell_pixel_update_retries_exhausted,
};

struct GraphicsStatusEvent {
    std::optional<std::uint16_t> attempts{};
    std::optional<std::uint16_t> cell_height{};
    std::optional<std::uint16_t> cell_width{};
    std::optional<std::string> error{};
    GraphicsStatusEventKind kind{};
    std::optional<std::uint64_t> remaining{};
    std::optional<bool> retry_exhausted{};
    std::optional<std::string> summary{};
    friend bool operator==(const GraphicsStatusEvent&, const GraphicsStatusEvent&) = default;
};

enum class IdMappingKind {
    workspace,
    screen,
    pane,
    surface,
};

struct IdMapping {
    Id id{};
    IdMappingKind kind{};
    std::string short_id{};
    friend bool operator==(const IdMapping&, const IdMapping&) = default;
};

struct IdentifyRequest {
    friend bool operator==(const IdentifyRequest&, const IdentifyRequest&) = default;
};

struct IdentifyResult {
    Field<std::string> build_commit{};
    std::optional<std::vector<std::string>> capabilities{};
    std::string generation{};
    Field<std::string> ghostty_commit{};
    std::optional<bool> lifecycle_ready{};
    std::uint32_t pid{};
    std::uint32_t protocol{};
    std::string registry_id{};
    std::string session{};
    std::uint64_t terminal_revision{};
    std::string version{};
    std::uint64_t workspace_revision{};
    friend bool operator==(const IdentifyResult&, const IdentifyResult&) = default;
};

enum class IdsRequestKind {
    workspace,
    screen,
    pane,
    surface,
};

struct IdsRequest {
    Field<IdsRequestKind> kind{};
    friend bool operator==(const IdsRequest&, const IdsRequest&) = default;
};

struct IdsResult {
    std::vector<IdMapping> ids{};
    friend bool operator==(const IdsResult&, const IdsResult&) = default;
};

struct JournalFrontendEventRequest {
    FrontendJournalEvent event{};
    friend bool operator==(const JournalFrontendEventRequest&, const JournalFrontendEventRequest&) = default;
};

struct JournalFrontendEventResult {
    friend bool operator==(const JournalFrontendEventResult&, const JournalFrontendEventResult&) = default;
};

struct KittyGraphicsState {
    std::uint32_t alternate_next_image_id{};
    std::uint32_t alternate_replay_next_image_id{};
    std::uint64_t image_bytes{};
    std::uint64_t images{};
    std::uint64_t inflight_bytes{};
    std::uint64_t placements{};
    std::uint32_t primary_next_image_id{};
    std::uint32_t primary_replay_next_image_id{};
    std::uint32_t replay_cursor_offset{};
    friend bool operator==(const KittyGraphicsState&, const KittyGraphicsState&) = default;
};

struct KittyImageAlias {
    std::uint32_t image_id{};
    std::uint32_t image_number{};
    friend bool operator==(const KittyImageAlias&, const KittyImageAlias&) = default;
};

struct LayoutChangedEvent {
    Id screen{};
    friend bool operator==(const LayoutChangedEvent&, const LayoutChangedEvent&) = default;
};

struct LayoutUndoConfirmationRequired {
    std::vector<Id> closes_panes{};
    std::uint64_t revision{};
    Id screen{};
    friend bool operator==(const LayoutUndoConfirmationRequired&, const LayoutUndoConfirmationRequired&) = default;
};

struct LayoutUndoUndone {
    std::optional<bool> confirmation_required{};
    std::uint64_t revision{};
    Id screen{};
    friend bool operator==(const LayoutUndoUndone&, const LayoutUndoUndone&) = default;
};

struct LayoutUndoResult {
    using Variant = std::variant<LayoutUndoUndone, LayoutUndoConfirmationRequired>;
    Variant value{};
    friend bool operator==(const LayoutUndoResult&, const LayoutUndoResult&) = default;
};

struct ListAgentsRequest {
    Field<AgentState> state{};
    Field<Id> surface{};
    friend bool operator==(const ListAgentsRequest&, const ListAgentsRequest&) = default;
};

struct ListAgentsResult {
    std::vector<AgentRecord> agents{};
    friend bool operator==(const ListAgentsResult&, const ListAgentsResult&) = default;
};

struct ListClientsRequest {
    friend bool operator==(const ListClientsRequest&, const ListClientsRequest&) = default;
};

struct ListClientsResult {
    std::vector<ClientInfo> value{};
    friend bool operator==(const ListClientsResult&, const ListClientsResult&) = default;
};

struct ListTerminalsRequest {
    friend bool operator==(const ListTerminalsRequest&, const ListTerminalsRequest&) = default;
};

struct TerminalExitOutcomeExit {
    std::int32_t code{};
    friend bool operator==(const TerminalExitOutcomeExit&, const TerminalExitOutcomeExit&) = default;
};

struct TerminalExitOutcomeSignal {
    bool core_dumped{};
    std::int32_t signal{};
    friend bool operator==(const TerminalExitOutcomeSignal&, const TerminalExitOutcomeSignal&) = default;
};

struct TerminalExitOutcomeUnknown {
    std::string reason{};
    friend bool operator==(const TerminalExitOutcomeUnknown&, const TerminalExitOutcomeUnknown&) = default;
};

struct TerminalExitOutcome {
    using Variant = std::variant<TerminalExitOutcomeExit, TerminalExitOutcomeSignal, TerminalExitOutcomeUnknown>;
    Variant value{};
    friend bool operator==(const TerminalExitOutcome&, const TerminalExitOutcome&) = default;
};

struct TerminalExit {
    std::uint64_t exited_at_ms{};
    TerminalExitOutcome outcome{};
    friend bool operator==(const TerminalExit&, const TerminalExit&) = default;
};

enum class TerminalLifecycle {
    launching,
    adopting,
    running,
    exited,
    tombstoned,
};

struct TerminalRecord {
    std::optional<TerminalExit> exit{};
    JsonValue launch_spec{};
    TerminalLifecycle lifecycle{};
    std::string terminal_id{};
    std::optional<std::string> terminal_incarnation{};
    std::string workspace_key{};
    friend bool operator==(const TerminalRecord&, const TerminalRecord&) = default;
};

struct ListTerminalsResult {
    std::string generation{};
    std::string registry_id{};
    std::uint64_t terminal_revision{};
    std::vector<TerminalRecord> terminals{};
    friend bool operator==(const ListTerminalsResult&, const ListTerminalsResult&) = default;
};

struct ListWorkspacesRequest {
    friend bool operator==(const ListWorkspacesRequest&, const ListWorkspacesRequest&) = default;
};

enum class NotificationLevel {
    info,
    warning,
    error,
};

struct NotificationMarker {
    NotificationLevel level{};
    Id notification{};
    bool unread{};
    friend bool operator==(const NotificationMarker&, const NotificationMarker&) = default;
};

struct Size {
    std::uint16_t cols{};
    std::uint16_t rows{};
    friend bool operator==(const Size&, const Size&) = default;
};

enum class TabBrowserSource {
    external,
    launched,
};

enum class TabBrowserStatus {
    starting,
    live,
    failed,
};

enum class TabKind {
    pty,
    browser,
};

struct Tab {
    Field<std::string> browser_error{};
    Field<bool> browser_frames_stalled{};
    std::optional<TabBrowserSource> browser_source{};
    Field<TabBrowserStatus> browser_status{};
    bool dead{};
    TabKind kind{};
    std::optional<std::string> name{};
    Field<NotificationMarker> notification{};
    std::optional<std::string> short_id{};
    std::optional<Size> size{};
    std::optional<bool> supports_clear_history_key_fallback{};
    Id surface{};
    Field<std::string> terminal_id{};
    Field<std::string> terminal_incarnation{};
    Field<std::string> terminal_resource_id{};
    std::string title{};
    friend bool operator==(const Tab&, const Tab&) = default;
};

struct LivePane {
    std::uint64_t active_tab{};
    std::optional<std::uint64_t> focused_at{};
    Id id{};
    std::optional<std::string> name{};
    std::optional<std::string> short_id{};
    std::vector<Tab> tabs{};
    friend bool operator==(const LivePane&, const LivePane&) = default;
};

struct MachineUsage {
    double api_equivalent_usd{};
    std::optional<std::string> as_of{};
    std::uint32_t period_days{};
    std::uint64_t total_tokens{};
    std::string vm_id{};
    friend bool operator==(const MachineUsage&, const MachineUsage&) = default;
};

struct MachineUsageChangedEvent {
    std::optional<MachineUsage> usage{};
    friend bool operator==(const MachineUsageChangedEvent&, const MachineUsageChangedEvent&) = default;
};

struct MachineUsageRequest {
    friend bool operator==(const MachineUsageRequest&, const MachineUsageRequest&) = default;
};

struct MachineUsageResult {
    std::optional<MachineUsage> usage{};
    friend bool operator==(const MachineUsageResult&, const MachineUsageResult&) = default;
};

struct MarkWorkspacesProviderManagedRequest {
    std::string authority{};
    friend bool operator==(const MarkWorkspacesProviderManagedRequest&, const MarkWorkspacesProviderManagedRequest&) = default;
};

struct MintTerminalRendererByTerminalRequest {
    std::string terminal{};
    std::optional<std::uint64_t> ttl_ms{};
    friend bool operator==(const MintTerminalRendererByTerminalRequest&, const MintTerminalRendererByTerminalRequest&) = default;
};

struct MintTerminalRendererRequest {
    Id surface{};
    std::optional<std::uint64_t> ttl_ms{};
    friend bool operator==(const MintTerminalRendererRequest&, const MintTerminalRendererRequest&) = default;
};

struct MintTerminalRendererResult {
    std::string endpoint{};
    std::string incarnation{};
    std::uint16_t protocol_version{};
    std::uint32_t rights{};
    std::string terminal_id{};
    std::string token{};
    std::uint64_t ttl_ms{};
    friend bool operator==(const MintTerminalRendererResult&, const MintTerminalRendererResult&) = default;
};

struct MoveTabRequest {
    std::uint64_t index{};
    Id pane{};
    Id surface{};
    friend bool operator==(const MoveTabRequest&, const MoveTabRequest&) = default;
};

struct MoveTerminalRequest {
    Field<std::string> expected_generation{};
    Field<std::uint64_t> expected_revision{};
    Field<std::string> mutation_id{};
    Field<std::string> origin{};
    std::string terminal_id{};
    Field<std::string> terminal_incarnation{};
    std::string workspace_key{};
    friend bool operator==(const MoveTerminalRequest&, const MoveTerminalRequest&) = default;
};

struct MoveTerminalResult {
    bool changed{};
    std::string generation{};
    TerminalLifecycle lifecycle{};
    std::optional<Id> pane{};
    std::string registry_id{};
    bool replayed{};
    std::optional<Id> screen{};
    std::optional<Id> surface{};
    std::string terminal_id{};
    std::optional<std::string> terminal_incarnation{};
    std::uint64_t terminal_revision{};
    std::optional<Id> workspace{};
    std::string workspace_key{};
    friend bool operator==(const MoveTerminalResult&, const MoveTerminalResult&) = default;
};

struct MoveWorkspaceRequest {
    Field<std::string> expected_generation{};
    Field<std::uint64_t> expected_revision{};
    std::uint64_t index{};
    Field<std::string> key{};
    Field<std::string> mutation_id{};
    Field<std::string> origin{};
    Field<Id> workspace{};
    friend bool operator==(const MoveWorkspaceRequest&, const MoveWorkspaceRequest&) = default;
};

struct NewBrowserTabRequest {
    Field<std::uint16_t> cols{};
    Field<Id> pane{};
    Field<std::uint16_t> rows{};
    std::string url{};
    friend bool operator==(const NewBrowserTabRequest&, const NewBrowserTabRequest&) = default;
};

struct NewPaneRequest {
    Field<std::uint16_t> cols{};
    Id pane{};
    Field<std::uint16_t> rows{};
    friend bool operator==(const NewPaneRequest&, const NewPaneRequest&) = default;
};

struct NewPaneRightRequest {
    Field<std::uint16_t> cols{};
    Id pane{};
    Field<std::uint16_t> rows{};
    Field<float> width{};
    friend bool operator==(const NewPaneRightRequest&, const NewPaneRightRequest&) = default;
};

struct NewScreenRequest {
    Field<std::uint16_t> cols{};
    Field<std::uint16_t> rows{};
    Field<Id> workspace{};
    friend bool operator==(const NewScreenRequest&, const NewScreenRequest&) = default;
};

struct NewTabRequest {
    Field<std::uint16_t> cols{};
    Field<std::string> cwd{};
    Field<Id> pane{};
    Field<std::uint16_t> rows{};
    friend bool operator==(const NewTabRequest&, const NewTabRequest&) = default;
};

struct NewWorkspaceRequest {
    Field<std::uint16_t> cols{};
    Field<std::string> name{};
    Field<std::uint16_t> rows{};
    friend bool operator==(const NewWorkspaceRequest&, const NewWorkspaceRequest&) = default;
};

struct NotificationEvent {
    std::string body{};
    NotificationLevel level{};
    Id notification{};
    std::optional<Id> surface{};
    std::string title{};
    friend bool operator==(const NotificationEvent&, const NotificationEvent&) = default;
};

struct NotifyRequest {
    std::string body{};
    Field<NotificationLevel> level{};
    Field<Id> surface{};
    std::string title{};
    friend bool operator==(const NotifyRequest&, const NotifyRequest&) = default;
};

struct NotifyResult {
    Id notification{};
    friend bool operator==(const NotifyResult&, const NotifyResult&) = default;
};

struct TerminalColors {
    std::optional<ColorHex> bg{};
    Field<ColorHex> cursor{};
    Field<bool> cursor_blink{};
    Field<CursorStyle> cursor_style{};
    std::optional<ColorHex> fg{};
    std::optional<std::map<std::string, ColorHex, std::less<>>> palette{};
    std::optional<ColorHex> selection_bg{};
    std::optional<ColorHex> selection_fg{};
    friend bool operator==(const TerminalColors&, const TerminalColors&) = default;
};

struct OutputEvent {
    std::optional<TerminalColors> colors{};
    Base64 data{};
    Id surface{};
    friend bool operator==(const OutputEvent&, const OutputEvent&) = default;
};

struct OverflowEvent {
    std::string error{};
    std::optional<std::string> scope{};
    std::optional<Id> surface{};
    friend bool operator==(const OverflowEvent&, const OverflowEvent&) = default;
};

struct PairingRequestedEvent {
    std::string code{};
    std::uint64_t expires_in{};
    std::string peer{};
    std::uint64_t request{};
    friend bool operator==(const PairingRequestedEvent&, const PairingRequestedEvent&) = default;
};

struct PairingResolvedEvent {
    std::uint64_t request{};
    friend bool operator==(const PairingResolvedEvent&, const PairingResolvedEvent&) = default;
};

struct PairingResponseRequest {
    bool approve{};
    std::uint64_t request{};
    friend bool operator==(const PairingResponseRequest&, const PairingResponseRequest&) = default;
};

struct Pane {
    using Variant = std::variant<LivePane, DeadPane>;
    Variant value{};
    friend bool operator==(const Pane&, const Pane&) = default;
};

struct PaneAddedEvent {
    Pane entity{};
    std::uint64_t index{};
    Id pane{};
    Id screen{};
    Id workspace{};
    friend bool operator==(const PaneAddedEvent&, const PaneAddedEvent&) = default;
};

struct PaneClosedEvent {
    Pane entity{};
    std::uint64_t index{};
    Id pane{};
    Id screen{};
    Id workspace{};
    friend bool operator==(const PaneClosedEvent&, const PaneClosedEvent&) = default;
};

struct PaneNeighborRequest {
    PaneDirection dir{};
    Id pane{};
    friend bool operator==(const PaneNeighborRequest&, const PaneNeighborRequest&) = default;
};

struct PaneNeighborResult {
    std::optional<Id> pane{};
    friend bool operator==(const PaneNeighborResult&, const PaneNeighborResult&) = default;
};

struct PingRequest {
    friend bool operator==(const PingRequest&, const PingRequest&) = default;
};

struct PingResult {
    Field<std::string> build_commit{};
    Field<std::string> ghostty_commit{};
    std::uint32_t protocol{};
    std::string version{};
    friend bool operator==(const PingResult&, const PingResult&) = default;
};

struct ProcessInfoRequest {
    Id surface{};
    friend bool operator==(const ProcessInfoRequest&, const ProcessInfoRequest&) = default;
};

struct ProcessInfoResult {
    std::optional<std::string> command{};
    std::optional<std::string> cwd{};
    Field<std::string> foreground_cwd{};
    std::optional<std::uint32_t> pid{};
    friend bool operator==(const ProcessInfoResult&, const ProcessInfoResult&) = default;
};

struct ProviderWorkspaceMutationResult {
    std::string key{};
    Id workspace{};
    std::uint64_t workspace_revision{};
    friend bool operator==(const ProviderWorkspaceMutationResult&, const ProviderWorkspaceMutationResult&) = default;
};

struct PutFrontendProjectionRequest {
    Field<std::string> expected_generation{};
    Field<std::uint64_t> expected_projection_revision{};
    Field<std::uint64_t> expected_revision{};
    std::string frontend{};
    Field<std::string> mutation_id{};
    Field<std::string> origin{};
    std::optional<JsonValue> projection{};
    std::uint32_t schema_version{};
    std::string scope{};
    std::string subject_key{};
    friend bool operator==(const PutFrontendProjectionRequest&, const PutFrontendProjectionRequest&) = default;
};

struct ReadScreenRequest {
    Id surface{};
    friend bool operator==(const ReadScreenRequest&, const ReadScreenRequest&) = default;
};

struct ReadScreenResult {
    std::string text{};
    friend bool operator==(const ReadScreenResult&, const ReadScreenResult&) = default;
};

struct ReadScrollbackRequest {
    std::uint32_t count{};
    std::uint32_t start{};
    Id surface{};
    friend bool operator==(const ReadScrollbackRequest&, const ReadScrollbackRequest&) = default;
};

enum class RenderUnderline {
    single,
    double_,
    curly,
    dotted,
    dashed,
};

struct RenderRun {
    std::uint32_t attrs{};
    std::optional<ColorHex> bg{};
    std::optional<ColorHex> fg{};
    std::string text{};
    std::optional<RenderUnderline> underline{};
    std::optional<std::uint16_t> width_hint{};
    friend bool operator==(const RenderRun&, const RenderRun&) = default;
};

struct RenderRow {
    std::uint32_t row{};
    std::vector<RenderRun> runs{};
    friend bool operator==(const RenderRow&, const RenderRow&) = default;
};

struct ReadScrollbackResult {
    std::uint64_t epoch{};
    std::vector<RenderRow> rows{};
    std::uint32_t start{};
    std::uint32_t total{};
    friend bool operator==(const ReadScrollbackResult&, const ReadScrollbackResult&) = default;
};

struct RegisterBrowserProviderRequest {
    BrowserProviderAuthentication authentication{};
    Field<std::string> bearer_token{};
    std::string endpoint{};
    std::string provider_id{};
    std::vector<BrowserProviderTarget> targets{};
    friend bool operator==(const RegisterBrowserProviderRequest&, const RegisterBrowserProviderRequest&) = default;
};

struct ReleaseAttachedViewSizeRequest {
    std::string lease{};
    Id surface{};
    friend bool operator==(const ReleaseAttachedViewSizeRequest&, const ReleaseAttachedViewSizeRequest&) = default;
};

struct ReleaseSurfaceSizeRequest {
    Id surface{};
    friend bool operator==(const ReleaseSurfaceSizeRequest&, const ReleaseSurfaceSizeRequest&) = default;
};

struct ReloadConfigRequest {
    friend bool operator==(const ReloadConfigRequest&, const ReloadConfigRequest&) = default;
};

struct ReloadConfigResult {
    std::optional<std::string> path{};
    friend bool operator==(const ReloadConfigResult&, const ReloadConfigResult&) = default;
};

struct RenamePaneRequest {
    std::string name{};
    Id pane{};
    friend bool operator==(const RenamePaneRequest&, const RenamePaneRequest&) = default;
};

struct RenameProviderManagedWorkspaceRequest {
    std::string authority{};
    std::string key{};
    std::string name{};
    Id workspace{};
    friend bool operator==(const RenameProviderManagedWorkspaceRequest&, const RenameProviderManagedWorkspaceRequest&) = default;
};

struct RenameScreenRequest {
    std::string name{};
    Id screen{};
    friend bool operator==(const RenameScreenRequest&, const RenameScreenRequest&) = default;
};

struct RenameSurfaceRequest {
    std::string name{};
    Id surface{};
    friend bool operator==(const RenameSurfaceRequest&, const RenameSurfaceRequest&) = default;
};

struct RenameWorkspaceRequest {
    Field<std::string> expected_generation{};
    Field<std::uint64_t> expected_revision{};
    Field<std::string> key{};
    Field<std::string> mutation_id{};
    std::string name{};
    Field<std::string> origin{};
    Field<Id> workspace{};
    friend bool operator==(const RenameWorkspaceRequest&, const RenameWorkspaceRequest&) = default;
};

struct RenderCursor {
    bool blink{};
    std::optional<ColorHex> color{};
    CursorStyle style{};
    bool visible{};
    std::uint16_t x{};
    std::uint16_t y{};
    friend bool operator==(const RenderCursor&, const RenderCursor&) = default;
};

enum class RenderGraphicFormat {
    rgb,
    rgba,
};

struct RenderGraphicImage {
    Base64 data{};
    RenderGraphicFormat format{};
    std::uint64_t generation{};
    std::uint32_t height{};
    std::uint32_t id{};
    std::uint32_t width{};
    friend bool operator==(const RenderGraphicImage&, const RenderGraphicImage&) = default;
};

struct RenderGraphicPlacement {
    std::optional<std::uint16_t> anchor_col{};
    std::optional<std::uint32_t> anchor_row{};
    std::uint32_t columns{};
    std::uint32_t grid_cols{};
    std::uint32_t grid_rows{};
    std::uint32_t image_id{};
    std::uint32_t ordinal{};
    std::uint32_t pixel_height{};
    std::uint32_t pixel_width{};
    std::uint32_t placement_id{};
    std::uint32_t rows{};
    std::uint32_t source_height{};
    std::uint32_t source_width{};
    std::uint32_t source_x{};
    std::uint32_t source_y{};
    std::int32_t viewport_col{};
    std::int32_t viewport_row{};
    bool viewport_visible{};
    std::uint32_t x_offset{};
    std::uint32_t y_offset{};
    std::int32_t z{};
    friend bool operator==(const RenderGraphicPlacement&, const RenderGraphicPlacement&) = default;
};

struct RenderGraphicsDelta {
    std::uint64_t generation{};
    std::optional<std::vector<RenderGraphicImage>> images{};
    std::optional<std::vector<RenderGraphicPlacement>> placements{};
    std::optional<std::vector<std::uint32_t>> removed_image_ids{};
    friend bool operator==(const RenderGraphicsDelta&, const RenderGraphicsDelta&) = default;
};

struct RenderDeltaEvent {
    RenderCursor cursor{};
    std::optional<ColorHex> default_bg{};
    std::optional<ColorHex> default_fg{};
    bool full{};
    std::optional<RenderGraphicsDelta> graphics{};
    std::optional<std::uint64_t> history_epoch{};
    std::vector<RenderRow> rows{};
    std::optional<std::uint32_t> scrollback_rows{};
    std::optional<Size> size{};
    Id surface{};
    friend bool operator==(const RenderDeltaEvent&, const RenderDeltaEvent&) = default;
};

struct RenderGraphics {
    std::uint64_t generation{};
    std::optional<std::vector<RenderGraphicImage>> images{};
    std::vector<RenderGraphicPlacement> placements{};
    std::optional<std::vector<std::uint32_t>> removed_image_ids{};
    friend bool operator==(const RenderGraphics&, const RenderGraphics&) = default;
};

struct RenderStateEvent {
    RenderCursor cursor{};
    ColorHex default_bg{};
    ColorHex default_fg{};
    std::optional<RenderGraphics> graphics{};
    std::uint64_t history_epoch{};
    std::vector<RenderRow> rows{};
    std::uint32_t scrollback_rows{};
    Size size{};
    Id surface{};
    friend bool operator==(const RenderStateEvent&, const RenderStateEvent&) = default;
};

struct ReportAgentRequest {
    Field<std::string> session{};
    AgentReportSource source{};
    AgentState state{};
    Id surface{};
    friend bool operator==(const ReportAgentRequest&, const ReportAgentRequest&) = default;
};

struct ReportAgentResult {
    std::optional<std::string> session{};
    AgentReportSource source{};
    AgentState state{};
    Id surface{};
    friend bool operator==(const ReportAgentResult&, const ReportAgentResult&) = default;
};

struct ReportFocusRequest {
    std::string client_id{};
    Id pane{};
    Field<std::uint64_t> tab{};
    friend bool operator==(const ReportFocusRequest&, const ReportFocusRequest&) = default;
};

struct ResizeAttachedViewRequest {
    std::uint16_t cols{};
    std::string lease{};
    std::uint16_t rows{};
    Id surface{};
    friend bool operator==(const ResizeAttachedViewRequest&, const ResizeAttachedViewRequest&) = default;
};

struct ResizeSurfaceRequest {
    std::uint16_t cols{};
    std::uint16_t rows{};
    Id surface{};
    friend bool operator==(const ResizeSurfaceRequest&, const ResizeSurfaceRequest&) = default;
};

struct ResizeSurfaceResult {
    bool accepted{};
    std::optional<std::uint64_t> reservation_id{};
    friend bool operator==(const ResizeSurfaceResult&, const ResizeSurfaceResult&) = default;
};

struct ResizedEvent {
    std::optional<TerminalColors> colors{};
    std::uint16_t cols{};
    std::optional<Base64> data{};
    std::optional<KittyGraphicsState> kitty_graphics_state{};
    std::optional<std::vector<KittyImageAlias>> kitty_image_aliases{};
    std::optional<Base64> replay{};
    std::uint16_t rows{};
    Id surface{};
    friend bool operator==(const ResizedEvent&, const ResizedEvent&) = default;
};

struct ResolveTerminalRequest {
    std::string terminal_id{};
    friend bool operator==(const ResolveTerminalRequest&, const ResolveTerminalRequest&) = default;
};

struct ResolveTerminalResult {
    std::optional<TerminalExit> exit{};
    std::string generation{};
    JsonValue launch_spec{};
    TerminalLifecycle lifecycle{};
    std::string registry_id{};
    std::optional<Id> surface{};
    std::string terminal_id{};
    std::optional<std::string> terminal_incarnation{};
    std::uint64_t terminal_revision{};
    std::string workspace_key{};
    friend bool operator==(const ResolveTerminalResult&, const ResolveTerminalResult&) = default;
};

struct RunRequest {
    Field<std::vector<std::string>> argv{};
    Field<std::uint16_t> cols{};
    Field<std::string> command{};
    Field<std::string> cwd{};
    Field<std::string> key{};
    Field<std::string> name{};
    std::optional<bool> new_workspace{};
    Field<Id> pane{};
    Field<std::uint16_t> rows{};
    friend bool operator==(const RunRequest&, const RunRequest&) = default;
};

struct RunResult {
    bool already_exited{};
    std::optional<TerminalExit> exit{};
    TerminalLifecycle lifecycle{};
    std::optional<Id> pane{};
    std::optional<Id> screen{};
    std::optional<Id> surface{};
    std::string terminal_id{};
    std::optional<std::string> terminal_incarnation{};
    std::uint64_t terminal_revision{};
    std::optional<Id> workspace{};
    friend bool operator==(const RunResult&, const RunResult&) = default;
};

struct Screen {
    bool active{};
    Id active_pane{};
    Id id{};
    Layout layout{};
    std::optional<std::string> name{};
    std::vector<Pane> panes{};
    std::optional<std::string> short_id{};
    std::optional<Id> zoomed_pane{};
    friend bool operator==(const Screen&, const Screen&) = default;
};

struct ScreenAddedEvent {
    Screen entity{};
    std::uint64_t index{};
    Id screen{};
    Id workspace{};
    friend bool operator==(const ScreenAddedEvent&, const ScreenAddedEvent&) = default;
};

struct ScreenClosedEvent {
    Screen entity{};
    std::uint64_t index{};
    Id screen{};
    Id workspace{};
    friend bool operator==(const ScreenClosedEvent&, const ScreenClosedEvent&) = default;
};

struct ScreenRenamedEvent {
    Screen entity{};
    Id screen{};
    Id workspace{};
    friend bool operator==(const ScreenRenamedEvent&, const ScreenRenamedEvent&) = default;
};

struct ScrollChangedEvent {
    bool at_bottom{};
    std::uint64_t offset{};
    Id surface{};
    friend bool operator==(const ScrollChangedEvent&, const ScrollChangedEvent&) = default;
};

struct ScrollSurfaceRequest {
    std::int64_t delta{};
    Id surface{};
    friend bool operator==(const ScrollSurfaceRequest&, const ScrollSurfaceRequest&) = default;
};

struct SelectScreenRequest {
    Field<std::int64_t> delta{};
    Field<std::uint64_t> index{};
    friend bool operator==(const SelectScreenRequest&, const SelectScreenRequest&) = default;
};

struct SelectTabRequest {
    Field<std::int64_t> delta{};
    Field<std::uint64_t> index{};
    Field<Id> pane{};
    friend bool operator==(const SelectTabRequest&, const SelectTabRequest&) = default;
};

struct SelectWorkspaceRequest {
    Field<std::int64_t> delta{};
    Field<std::uint64_t> index{};
    friend bool operator==(const SelectWorkspaceRequest&, const SelectWorkspaceRequest&) = default;
};

struct SendKeyRequest {
    std::vector<std::string> keys{};
    Id surface{};
    friend bool operator==(const SendKeyRequest&, const SendKeyRequest&) = default;
};

struct SendRequest {
    Field<Base64> bytes{};
    std::optional<bool> paste{};
    Id surface{};
    Field<std::string> text{};
    friend bool operator==(const SendRequest&, const SendRequest&) = default;
};

struct SetCellPixelsRequest {
    std::uint16_t height_px{};
    std::uint16_t width_px{};
    friend bool operator==(const SetCellPixelsRequest&, const SetCellPixelsRequest&) = default;
};

struct SetCellPixelsResult {
    std::vector<CellPixelFailure> failures{};
    std::vector<CellPixelResize> resizes{};
    friend bool operator==(const SetCellPixelsResult&, const SetCellPixelsResult&) = default;
};

struct SetClientInfoRequest {
    Field<std::vector<std::string>> capabilities{};
    Field<std::string> kind{};
    Field<std::string> name{};
    friend bool operator==(const SetClientInfoRequest&, const SetClientInfoRequest&) = default;
};

struct SetClientSizingRequest {
    Field<std::uint64_t> client{};
    bool enabled{};
    std::optional<bool> exclusive{};
    Id surface{};
    friend bool operator==(const SetClientSizingRequest&, const SetClientSizingRequest&) = default;
};

struct SetDefaultColorsRequest {
    Field<ColorHex> bg{};
    std::optional<bool> complete{};
    Field<ColorHex> cursor{};
    Field<bool> cursor_blink{};
    Field<CursorStyle> cursor_style{};
    Field<ColorHex> fg{};
    Field<std::map<std::string, ColorHex, std::less<>>> palette{};
    Field<ColorHex> selection_bg{};
    Field<ColorHex> selection_fg{};
    friend bool operator==(const SetDefaultColorsRequest&, const SetDefaultColorsRequest&) = default;
};

struct SetRatioRequest {
    SplitDirection dir{};
    Id pane{};
    float ratio{};
    friend bool operator==(const SetRatioRequest&, const SetRatioRequest&) = default;
};

struct SetSplitRatioRequest {
    float ratio{};
    Id split{};
    Field<std::uint64_t> transaction{};
    friend bool operator==(const SetSplitRatioRequest&, const SetSplitRatioRequest&) = default;
};

struct SetViewportPaneWidthRequest {
    Id pane{};
    Field<std::uint64_t> transaction{};
    float width{};
    friend bool operator==(const SetViewportPaneWidthRequest&, const SetViewportPaneWidthRequest&) = default;
};

struct SetWindowTitleRequest {
    std::string title{};
    friend bool operator==(const SetWindowTitleRequest&, const SetWindowTitleRequest&) = default;
};

struct ShutdownDaemonRequest {
    std::optional<bool> force{};
    std::string generation{};
    std::uint32_t pid{};
    friend bool operator==(const ShutdownDaemonRequest&, const ShutdownDaemonRequest&) = default;
};

struct ShutdownDaemonResult {
    std::string generation{};
    std::uint32_t pid{};
    friend bool operator==(const ShutdownDaemonResult&, const ShutdownDaemonResult&) = default;
};

struct SidebarPluginRequest {
    std::uint16_t cols{};
    std::optional<bool> relaunch{};
    std::uint16_t rows{};
    friend bool operator==(const SidebarPluginRequest&, const SidebarPluginRequest&) = default;
};

struct SidebarPluginResult {
    std::optional<std::string> error{};
    std::optional<std::uint64_t> retry_after_ms{};
    std::optional<Id> surface{};
    friend bool operator==(const SidebarPluginResult&, const SidebarPluginResult&) = default;
};

struct SplitRequest {
    Field<std::uint16_t> cols{};
    SplitDirection dir{};
    Id pane{};
    Field<std::uint16_t> rows{};
    friend bool operator==(const SplitRequest&, const SplitRequest&) = default;
};

struct StatusEvent {
    std::string message{};
    friend bool operator==(const StatusEvent&, const StatusEvent&) = default;
};

enum class SubscribeRequestTreeEvents {
    coarse,
    deltas,
};

struct SubscribeRequest {
    Field<Id> surface{};
    Field<SubscribeRequestTreeEvents> tree_events{};
    friend bool operator==(const SubscribeRequest&, const SubscribeRequest&) = default;
};

struct SurfaceExitedEvent {
    Id surface{};
    friend bool operator==(const SurfaceExitedEvent&, const SurfaceExitedEvent&) = default;
};

struct SurfaceOutputEvent {
    Id surface{};
    friend bool operator==(const SurfaceOutputEvent&, const SurfaceOutputEvent&) = default;
};

struct SurfaceResizeFailedEvent {
    std::uint16_t cols{};
    std::string error{};
    std::optional<std::uint64_t> reservation_id{};
    std::optional<std::uint64_t> retry_after_ms{};
    std::uint16_t rows{};
    Id surface{};
    friend bool operator==(const SurfaceResizeFailedEvent&, const SurfaceResizeFailedEvent&) = default;
};

struct SurfaceResizedEvent {
    std::uint16_t cols{};
    std::optional<std::uint64_t> reservation_id{};
    std::uint16_t rows{};
    Id surface{};
    friend bool operator==(const SurfaceResizedEvent&, const SurfaceResizedEvent&) = default;
};

struct SurfaceResult {
    Id surface{};
    Field<std::string> terminal_id{};
    Field<std::string> terminal_incarnation{};
    friend bool operator==(const SurfaceResult&, const SurfaceResult&) = default;
};

struct SwapPaneRequest {
    Field<PaneDirection> dir{};
    Id pane{};
    Field<Id> target{};
    friend bool operator==(const SwapPaneRequest&, const SwapPaneRequest&) = default;
};

struct TabAddedEvent {
    Tab entity{};
    std::uint64_t index{};
    Id pane{};
    Id screen{};
    Id surface{};
    Id workspace{};
    friend bool operator==(const TabAddedEvent&, const TabAddedEvent&) = default;
};

struct TabClosedEvent {
    Tab entity{};
    std::uint64_t index{};
    Id pane{};
    Id screen{};
    Id surface{};
    Id workspace{};
    friend bool operator==(const TabClosedEvent&, const TabClosedEvent&) = default;
};

struct TabRenamedEvent {
    Tab entity{};
    Id pane{};
    Id screen{};
    Id surface{};
    Id workspace{};
    friend bool operator==(const TabRenamedEvent&, const TabRenamedEvent&) = default;
};

struct TerminalEventsRequest {
    std::optional<std::uint64_t> after_revision{};
    friend bool operator==(const TerminalEventsRequest&, const TerminalEventsRequest&) = default;
};

struct TerminalRegistryEvent {
    std::string kind{};
    std::string mutation_id{};
    std::string origin{};
    JsonValue result{};
    std::string terminal_id{};
    std::uint64_t terminal_revision{};
    std::string workspace_key{};
    friend bool operator==(const TerminalRegistryEvent&, const TerminalRegistryEvent&) = default;
};

struct TerminalEventsResult {
    std::vector<TerminalRegistryEvent> events{};
    std::string generation{};
    std::string registry_id{};
    std::uint64_t terminal_revision{};
    friend bool operator==(const TerminalEventsResult&, const TerminalEventsResult&) = default;
};

struct TerminalPlacement {
    bool already_exited{};
    std::optional<TerminalExit> exit{};
    std::string generation{};
    std::string key{};
    TerminalLifecycle lifecycle{};
    std::optional<Id> pane{};
    std::string registry_id{};
    bool replayed{};
    std::optional<Id> screen{};
    std::optional<Id> surface{};
    std::string terminal_id{};
    std::optional<std::string> terminal_incarnation{};
    std::uint64_t terminal_revision{};
    std::optional<Id> workspace{};
    friend bool operator==(const TerminalPlacement&, const TerminalPlacement&) = default;
};

struct TerminalRegistryChangedEvent {
    std::string generation{};
    std::string registry_id{};
    std::uint64_t terminal_revision{};
    friend bool operator==(const TerminalRegistryChangedEvent&, const TerminalRegistryChangedEvent&) = default;
};

struct TitleChangedEvent {
    Id surface{};
    std::optional<std::string> title{};
    friend bool operator==(const TitleChangedEvent&, const TitleChangedEvent&) = default;
};

struct Workspace {
    bool active{};
    Id id{};
    std::optional<std::string> key{};
    std::string name{};
    std::vector<Screen> screens{};
    std::optional<std::string> short_id{};
    friend bool operator==(const Workspace&, const Workspace&) = default;
};

struct Tree {
    std::optional<std::string> generation{};
    std::optional<std::uint64_t> pane_revision{};
    std::optional<std::string> registry_id{};
    std::optional<std::uint64_t> terminal_revision{};
    std::optional<std::uint64_t> workspace_revision{};
    std::vector<Workspace> workspaces{};
    friend bool operator==(const Tree&, const Tree&) = default;
};

struct TreeChangedEvent {
    friend bool operator==(const TreeChangedEvent&, const TreeChangedEvent&) = default;
};

struct UndoLayoutRequest {
    std::optional<bool> confirm_close{};
    Id pane{};
    Field<std::uint64_t> revision{};
    friend bool operator==(const UndoLayoutRequest&, const UndoLayoutRequest&) = default;
};

struct UnregisterBrowserProviderRequest {
    friend bool operator==(const UnregisterBrowserProviderRequest&, const UnregisterBrowserProviderRequest&) = default;
};

struct VtStateEvent {
    std::optional<TerminalColors> colors{};
    std::uint16_t cols{};
    Base64 data{};
    std::optional<KittyGraphicsState> kitty_graphics_state{};
    std::optional<std::vector<KittyImageAlias>> kitty_image_aliases{};
    std::uint16_t rows{};
    Id surface{};
    friend bool operator==(const VtStateEvent&, const VtStateEvent&) = default;
};

struct VtStateRequest {
    Id surface{};
    friend bool operator==(const VtStateRequest&, const VtStateRequest&) = default;
};

struct VtStateResult {
    std::uint16_t cols{};
    Base64 data{};
    std::optional<KittyGraphicsState> kitty_graphics_state{};
    std::optional<std::vector<KittyImageAlias>> kitty_image_aliases{};
    std::uint16_t rows{};
    friend bool operator==(const VtStateResult&, const VtStateResult&) = default;
};

struct WaitForRequest {
    std::string pattern{};
    Id surface{};
    std::uint64_t timeout_ms{};
    friend bool operator==(const WaitForRequest&, const WaitForRequest&) = default;
};

struct WaitForResult {
    std::uint64_t elapsed_ms{};
    std::string text{};
    friend bool operator==(const WaitForResult&, const WaitForResult&) = default;
};

struct WindowTitleRequestedEvent {
    std::string title{};
    friend bool operator==(const WindowTitleRequestedEvent&, const WindowTitleRequestedEvent&) = default;
};

struct WorkspaceAddedEvent {
    Workspace entity{};
    std::string generation{};
    std::uint64_t index{};
    std::optional<std::string> mutation_id{};
    std::optional<std::string> origin{};
    std::string registry_id{};
    Id workspace{};
    std::uint64_t workspace_revision{};
    friend bool operator==(const WorkspaceAddedEvent&, const WorkspaceAddedEvent&) = default;
};

struct WorkspaceClosedEvent {
    Workspace entity{};
    std::string generation{};
    std::uint64_t index{};
    std::optional<std::string> mutation_id{};
    std::optional<std::string> origin{};
    std::string registry_id{};
    Id workspace{};
    std::uint64_t workspace_revision{};
    friend bool operator==(const WorkspaceClosedEvent&, const WorkspaceClosedEvent&) = default;
};

struct WorkspaceMovedEvent {
    Workspace entity{};
    std::string generation{};
    std::uint64_t index{};
    std::optional<std::string> mutation_id{};
    std::optional<std::string> origin{};
    std::string registry_id{};
    Id workspace{};
    std::uint64_t workspace_revision{};
    friend bool operator==(const WorkspaceMovedEvent&, const WorkspaceMovedEvent&) = default;
};

struct WorkspaceMutationResult {
    std::optional<bool> changed{};
    std::string generation{};
    std::uint64_t index{};
    std::string key{};
    std::string registry_id{};
    bool replayed{};
    Id workspace{};
    std::uint64_t workspace_revision{};
    friend bool operator==(const WorkspaceMutationResult&, const WorkspaceMutationResult&) = default;
};

struct WorkspaceRenamedEvent {
    Workspace entity{};
    std::string generation{};
    std::optional<std::string> mutation_id{};
    std::optional<std::string> origin{};
    std::string registry_id{};
    Id workspace{};
    std::uint64_t workspace_revision{};
    friend bool operator==(const WorkspaceRenamedEvent&, const WorkspaceRenamedEvent&) = default;
};

enum class ZoomPaneRequestMode {
    toggle,
    on,
    off,
};

struct ZoomPaneRequest {
    Field<ZoomPaneRequestMode> mode{};
    Field<Id> pane{};
    friend bool operator==(const ZoomPaneRequest&, const ZoomPaneRequest&) = default;
};

struct ZoomPaneResult {
    Id pane{};
    bool zoomed{};
    std::optional<Id> zoomed_pane{};
    friend bool operator==(const ZoomPaneResult&, const ZoomPaneResult&) = default;
};

template <>
struct Codec<AgentRecord> {
    static Result<Json> encode(const AgentRecord& value);
    static Result<AgentRecord> decode(const Json& value);
};

template <>
struct Codec<AgentReportSource> {
    static Result<Json> encode(const AgentReportSource& value);
    static Result<AgentReportSource> decode(const Json& value);
};

template <>
struct Codec<AgentSource> {
    static Result<Json> encode(const AgentSource& value);
    static Result<AgentSource> decode(const Json& value);
};

template <>
struct Codec<AgentState> {
    static Result<Json> encode(const AgentState& value);
    static Result<AgentState> decode(const Json& value);
};

template <>
struct Codec<AppliedPane> {
    static Result<Json> encode(const AppliedPane& value);
    static Result<AppliedPane> decode(const Json& value);
};

template <>
struct Codec<ApplyLayoutResult> {
    static Result<Json> encode(const ApplyLayoutResult& value);
    static Result<ApplyLayoutResult> decode(const Json& value);
};

template <>
struct Codec<AttachedViewOutcomeResult> {
    static Result<Json> encode(const AttachedViewOutcomeResult& value);
    static Result<AttachedViewOutcomeResult> decode(const Json& value);
};

template <>
struct Codec<AttachedViewResizeResult> {
    static Result<Json> encode(const AttachedViewResizeResult& value);
    static Result<AttachedViewResizeResult> decode(const Json& value);
};

template <>
struct Codec<Base64> {
    static Result<Json> encode(const Base64& value);
    static Result<Base64> decode(const Json& value);
};

template <>
struct Codec<BrowserFrame> {
    static Result<Json> encode(const BrowserFrame& value);
    static Result<BrowserFrame> decode(const Json& value);
};

template <>
struct Codec<BrowserProviderAuthentication> {
    static Result<Json> encode(const BrowserProviderAuthentication& value);
    static Result<BrowserProviderAuthentication> decode(const Json& value);
};

template <>
struct Codec<BrowserProviderSnapshot> {
    static Result<Json> encode(const BrowserProviderSnapshot& value);
    static Result<BrowserProviderSnapshot> decode(const Json& value);
};

template <>
struct Codec<BrowserProviderTarget> {
    static Result<Json> encode(const BrowserProviderTarget& value);
    static Result<BrowserProviderTarget> decode(const Json& value);
};

template <>
struct Codec<BrowserProviderUnregisterResult> {
    static Result<Json> encode(const BrowserProviderUnregisterResult& value);
    static Result<BrowserProviderUnregisterResult> decode(const Json& value);
};

template <>
struct Codec<CellPixelFailure> {
    static Result<Json> encode(const CellPixelFailure& value);
    static Result<CellPixelFailure> decode(const Json& value);
};

template <>
struct Codec<CellPixelResize> {
    static Result<Json> encode(const CellPixelResize& value);
    static Result<CellPixelResize> decode(const Json& value);
};

template <>
struct Codec<CellPixelSurface> {
    static Result<Json> encode(const CellPixelSurface& value);
    static Result<CellPixelSurface> decode(const Json& value);
};

template <>
struct Codec<ClientInfo> {
    static Result<Json> encode(const ClientInfo& value);
    static Result<ClientInfo> decode(const Json& value);
};

template <>
struct Codec<ClientSize> {
    static Result<Json> encode(const ClientSize& value);
    static Result<ClientSize> decode(const Json& value);
};

template <>
struct Codec<ClientTransport> {
    static Result<Json> encode(const ClientTransport& value);
    static Result<ClientTransport> decode(const Json& value);
};

template <>
struct Codec<CloseTerminalResult> {
    static Result<Json> encode(const CloseTerminalResult& value);
    static Result<CloseTerminalResult> decode(const Json& value);
};

template <>
struct Codec<ColorHex> {
    static Result<Json> encode(const ColorHex& value);
    static Result<ColorHex> decode(const Json& value);
};

template <>
struct Codec<CopyResult> {
    static Result<Json> encode(const CopyResult& value);
    static Result<CopyResult> decode(const Json& value);
};

template <>
struct Codec<CursorStyle> {
    static Result<Json> encode(const CursorStyle& value);
    static Result<CursorStyle> decode(const Json& value);
};

template <>
struct Codec<DeadPane> {
    static Result<Json> encode(const DeadPane& value);
    static Result<DeadPane> decode(const Json& value);
};

template <>
struct Codec<DeclarativeLayout> {
    static Result<Json> encode(const DeclarativeLayout& value);
    static Result<DeclarativeLayout> decode(const Json& value);
};

template <>
struct Codec<EmptyResult> {
    static Result<Json> encode(const EmptyResult& value);
    static Result<EmptyResult> decode(const Json& value);
};

template <>
struct Codec<ExportLayoutResult> {
    static Result<Json> encode(const ExportLayoutResult& value);
    static Result<ExportLayoutResult> decode(const Json& value);
};

template <>
struct Codec<ExportedPane> {
    static Result<Json> encode(const ExportedPane& value);
    static Result<ExportedPane> decode(const Json& value);
};

template <>
struct Codec<FocusDirectionResult> {
    static Result<Json> encode(const FocusDirectionResult& value);
    static Result<FocusDirectionResult> decode(const Json& value);
};

template <>
struct Codec<FrontendFocusTarget> {
    static Result<Json> encode(const FrontendFocusTarget& value);
    static Result<FrontendFocusTarget> decode(const Json& value);
};

template <>
struct Codec<FrontendJournalEvent> {
    static Result<Json> encode(const FrontendJournalEvent& value);
    static Result<FrontendJournalEvent> decode(const Json& value);
};

template <>
struct Codec<FrontendProjection> {
    static Result<Json> encode(const FrontendProjection& value);
    static Result<FrontendProjection> decode(const Json& value);
};

template <>
struct Codec<GetCellPixelsResult> {
    static Result<Json> encode(const GetCellPixelsResult& value);
    static Result<GetCellPixelsResult> decode(const Json& value);
};

template <>
struct Codec<Id> {
    static Result<Json> encode(const Id& value);
    static Result<Id> decode(const Json& value);
};

template <>
struct Codec<IdMapping> {
    static Result<Json> encode(const IdMapping& value);
    static Result<IdMapping> decode(const Json& value);
};

template <>
struct Codec<IdentifyResult> {
    static Result<Json> encode(const IdentifyResult& value);
    static Result<IdentifyResult> decode(const Json& value);
};

template <>
struct Codec<IdsResult> {
    static Result<Json> encode(const IdsResult& value);
    static Result<IdsResult> decode(const Json& value);
};

template <>
struct Codec<JsonValue> {
    static Result<Json> encode(const JsonValue& value);
    static Result<JsonValue> decode(const Json& value);
};

template <>
struct Codec<KittyGraphicsState> {
    static Result<Json> encode(const KittyGraphicsState& value);
    static Result<KittyGraphicsState> decode(const Json& value);
};

template <>
struct Codec<KittyImageAlias> {
    static Result<Json> encode(const KittyImageAlias& value);
    static Result<KittyImageAlias> decode(const Json& value);
};

template <>
struct Codec<Layout> {
    static Result<Json> encode(const Layout& value);
    static Result<Layout> decode(const Json& value);
};

template <>
struct Codec<LayoutUndoConfirmationRequired> {
    static Result<Json> encode(const LayoutUndoConfirmationRequired& value);
    static Result<LayoutUndoConfirmationRequired> decode(const Json& value);
};

template <>
struct Codec<LayoutUndoResult> {
    static Result<Json> encode(const LayoutUndoResult& value);
    static Result<LayoutUndoResult> decode(const Json& value);
};

template <>
struct Codec<LayoutUndoUndone> {
    static Result<Json> encode(const LayoutUndoUndone& value);
    static Result<LayoutUndoUndone> decode(const Json& value);
};

template <>
struct Codec<ListAgentsResult> {
    static Result<Json> encode(const ListAgentsResult& value);
    static Result<ListAgentsResult> decode(const Json& value);
};

template <>
struct Codec<ListTerminalsResult> {
    static Result<Json> encode(const ListTerminalsResult& value);
    static Result<ListTerminalsResult> decode(const Json& value);
};

template <>
struct Codec<LivePane> {
    static Result<Json> encode(const LivePane& value);
    static Result<LivePane> decode(const Json& value);
};

template <>
struct Codec<MachineUsage> {
    static Result<Json> encode(const MachineUsage& value);
    static Result<MachineUsage> decode(const Json& value);
};

template <>
struct Codec<MachineUsageResult> {
    static Result<Json> encode(const MachineUsageResult& value);
    static Result<MachineUsageResult> decode(const Json& value);
};

template <>
struct Codec<MintTerminalRendererResult> {
    static Result<Json> encode(const MintTerminalRendererResult& value);
    static Result<MintTerminalRendererResult> decode(const Json& value);
};

template <>
struct Codec<MoveTerminalResult> {
    static Result<Json> encode(const MoveTerminalResult& value);
    static Result<MoveTerminalResult> decode(const Json& value);
};

template <>
struct Codec<NotificationLevel> {
    static Result<Json> encode(const NotificationLevel& value);
    static Result<NotificationLevel> decode(const Json& value);
};

template <>
struct Codec<NotificationMarker> {
    static Result<Json> encode(const NotificationMarker& value);
    static Result<NotificationMarker> decode(const Json& value);
};

template <>
struct Codec<NotifyResult> {
    static Result<Json> encode(const NotifyResult& value);
    static Result<NotifyResult> decode(const Json& value);
};

template <>
struct Codec<Pane> {
    static Result<Json> encode(const Pane& value);
    static Result<Pane> decode(const Json& value);
};

template <>
struct Codec<PaneDirection> {
    static Result<Json> encode(const PaneDirection& value);
    static Result<PaneDirection> decode(const Json& value);
};

template <>
struct Codec<PaneNeighborResult> {
    static Result<Json> encode(const PaneNeighborResult& value);
    static Result<PaneNeighborResult> decode(const Json& value);
};

template <>
struct Codec<PingResult> {
    static Result<Json> encode(const PingResult& value);
    static Result<PingResult> decode(const Json& value);
};

template <>
struct Codec<ProcessInfoResult> {
    static Result<Json> encode(const ProcessInfoResult& value);
    static Result<ProcessInfoResult> decode(const Json& value);
};

template <>
struct Codec<ProviderWorkspaceMutationResult> {
    static Result<Json> encode(const ProviderWorkspaceMutationResult& value);
    static Result<ProviderWorkspaceMutationResult> decode(const Json& value);
};

template <>
struct Codec<ReadScreenResult> {
    static Result<Json> encode(const ReadScreenResult& value);
    static Result<ReadScreenResult> decode(const Json& value);
};

template <>
struct Codec<ReadScrollbackResult> {
    static Result<Json> encode(const ReadScrollbackResult& value);
    static Result<ReadScrollbackResult> decode(const Json& value);
};

template <>
struct Codec<RenderCursor> {
    static Result<Json> encode(const RenderCursor& value);
    static Result<RenderCursor> decode(const Json& value);
};

template <>
struct Codec<RenderGraphicFormat> {
    static Result<Json> encode(const RenderGraphicFormat& value);
    static Result<RenderGraphicFormat> decode(const Json& value);
};

template <>
struct Codec<RenderGraphicImage> {
    static Result<Json> encode(const RenderGraphicImage& value);
    static Result<RenderGraphicImage> decode(const Json& value);
};

template <>
struct Codec<RenderGraphicPlacement> {
    static Result<Json> encode(const RenderGraphicPlacement& value);
    static Result<RenderGraphicPlacement> decode(const Json& value);
};

template <>
struct Codec<RenderGraphics> {
    static Result<Json> encode(const RenderGraphics& value);
    static Result<RenderGraphics> decode(const Json& value);
};

template <>
struct Codec<RenderGraphicsDelta> {
    static Result<Json> encode(const RenderGraphicsDelta& value);
    static Result<RenderGraphicsDelta> decode(const Json& value);
};

template <>
struct Codec<RenderRow> {
    static Result<Json> encode(const RenderRow& value);
    static Result<RenderRow> decode(const Json& value);
};

template <>
struct Codec<RenderRun> {
    static Result<Json> encode(const RenderRun& value);
    static Result<RenderRun> decode(const Json& value);
};

template <>
struct Codec<RenderUnderline> {
    static Result<Json> encode(const RenderUnderline& value);
    static Result<RenderUnderline> decode(const Json& value);
};

template <>
struct Codec<ReportAgentResult> {
    static Result<Json> encode(const ReportAgentResult& value);
    static Result<ReportAgentResult> decode(const Json& value);
};

template <>
struct Codec<ResizeSurfaceResult> {
    static Result<Json> encode(const ResizeSurfaceResult& value);
    static Result<ResizeSurfaceResult> decode(const Json& value);
};

template <>
struct Codec<ResolveTerminalResult> {
    static Result<Json> encode(const ResolveTerminalResult& value);
    static Result<ResolveTerminalResult> decode(const Json& value);
};

template <>
struct Codec<ResourceSelectors> {
    static Result<Json> encode(const ResourceSelectors& value);
    static Result<ResourceSelectors> decode(const Json& value);
};

template <>
struct Codec<RunResult> {
    static Result<Json> encode(const RunResult& value);
    static Result<RunResult> decode(const Json& value);
};

template <>
struct Codec<Screen> {
    static Result<Json> encode(const Screen& value);
    static Result<Screen> decode(const Json& value);
};

template <>
struct Codec<SetCellPixelsResult> {
    static Result<Json> encode(const SetCellPixelsResult& value);
    static Result<SetCellPixelsResult> decode(const Json& value);
};

template <>
struct Codec<ShutdownDaemonResult> {
    static Result<Json> encode(const ShutdownDaemonResult& value);
    static Result<ShutdownDaemonResult> decode(const Json& value);
};

template <>
struct Codec<SidebarPluginResult> {
    static Result<Json> encode(const SidebarPluginResult& value);
    static Result<SidebarPluginResult> decode(const Json& value);
};

template <>
struct Codec<Size> {
    static Result<Json> encode(const Size& value);
    static Result<Size> decode(const Json& value);
};

template <>
struct Codec<SplitDirection> {
    static Result<Json> encode(const SplitDirection& value);
    static Result<SplitDirection> decode(const Json& value);
};

template <>
struct Codec<SurfaceResult> {
    static Result<Json> encode(const SurfaceResult& value);
    static Result<SurfaceResult> decode(const Json& value);
};

template <>
struct Codec<Tab> {
    static Result<Json> encode(const Tab& value);
    static Result<Tab> decode(const Json& value);
};

template <>
struct Codec<TerminalColors> {
    static Result<Json> encode(const TerminalColors& value);
    static Result<TerminalColors> decode(const Json& value);
};

template <>
struct Codec<TerminalEventsResult> {
    static Result<Json> encode(const TerminalEventsResult& value);
    static Result<TerminalEventsResult> decode(const Json& value);
};

template <>
struct Codec<TerminalExit> {
    static Result<Json> encode(const TerminalExit& value);
    static Result<TerminalExit> decode(const Json& value);
};

template <>
struct Codec<TerminalExitOutcome> {
    static Result<Json> encode(const TerminalExitOutcome& value);
    static Result<TerminalExitOutcome> decode(const Json& value);
};

template <>
struct Codec<TerminalKey> {
    static Result<Json> encode(const TerminalKey& value);
    static Result<TerminalKey> decode(const Json& value);
};

template <>
struct Codec<TerminalKeyAction> {
    static Result<Json> encode(const TerminalKeyAction& value);
    static Result<TerminalKeyAction> decode(const Json& value);
};

template <>
struct Codec<TerminalKeyInput> {
    static Result<Json> encode(const TerminalKeyInput& value);
    static Result<TerminalKeyInput> decode(const Json& value);
};

template <>
struct Codec<TerminalLifecycle> {
    static Result<Json> encode(const TerminalLifecycle& value);
    static Result<TerminalLifecycle> decode(const Json& value);
};

template <>
struct Codec<TerminalModifiers> {
    static Result<Json> encode(const TerminalModifiers& value);
    static Result<TerminalModifiers> decode(const Json& value);
};

template <>
struct Codec<TerminalPlacement> {
    static Result<Json> encode(const TerminalPlacement& value);
    static Result<TerminalPlacement> decode(const Json& value);
};

template <>
struct Codec<TerminalRecord> {
    static Result<Json> encode(const TerminalRecord& value);
    static Result<TerminalRecord> decode(const Json& value);
};

template <>
struct Codec<TerminalRegistryEvent> {
    static Result<Json> encode(const TerminalRegistryEvent& value);
    static Result<TerminalRegistryEvent> decode(const Json& value);
};

template <>
struct Codec<Tree> {
    static Result<Json> encode(const Tree& value);
    static Result<Tree> decode(const Json& value);
};

template <>
struct Codec<ViewAttachmentOutcome> {
    static Result<Json> encode(const ViewAttachmentOutcome& value);
    static Result<ViewAttachmentOutcome> decode(const Json& value);
};

template <>
struct Codec<VtStateResult> {
    static Result<Json> encode(const VtStateResult& value);
    static Result<VtStateResult> decode(const Json& value);
};

template <>
struct Codec<WaitForResult> {
    static Result<Json> encode(const WaitForResult& value);
    static Result<WaitForResult> decode(const Json& value);
};

template <>
struct Codec<Workspace> {
    static Result<Json> encode(const Workspace& value);
    static Result<Workspace> decode(const Json& value);
};

template <>
struct Codec<WorkspaceMutationResult> {
    static Result<Json> encode(const WorkspaceMutationResult& value);
    static Result<WorkspaceMutationResult> decode(const Json& value);
};

template <>
struct Codec<ZoomPaneResult> {
    static Result<Json> encode(const ZoomPaneResult& value);
    static Result<ZoomPaneResult> decode(const Json& value);
};

template <>
struct Codec<ApplyLayoutRequest> {
    static Result<Json> encode(const ApplyLayoutRequest& value);
    static Result<ApplyLayoutRequest> decode(const Json& value);
};

template <>
struct Codec<AttachSurfaceRequest> {
    static Result<Json> encode(const AttachSurfaceRequest& value);
    static Result<AttachSurfaceRequest> decode(const Json& value);
};

template <>
struct Codec<BrowserActivateRequest> {
    static Result<Json> encode(const BrowserActivateRequest& value);
    static Result<BrowserActivateRequest> decode(const Json& value);
};

template <>
struct Codec<BrowserBackRequest> {
    static Result<Json> encode(const BrowserBackRequest& value);
    static Result<BrowserBackRequest> decode(const Json& value);
};

template <>
struct Codec<BrowserForwardRequest> {
    static Result<Json> encode(const BrowserForwardRequest& value);
    static Result<BrowserForwardRequest> decode(const Json& value);
};

template <>
struct Codec<BrowserFramePresentedRequest> {
    static Result<Json> encode(const BrowserFramePresentedRequest& value);
    static Result<BrowserFramePresentedRequest> decode(const Json& value);
};

template <>
struct Codec<BrowserInsertTextRequest> {
    static Result<Json> encode(const BrowserInsertTextRequest& value);
    static Result<BrowserInsertTextRequest> decode(const Json& value);
};

template <>
struct Codec<BrowserKeyRequest> {
    static Result<Json> encode(const BrowserKeyRequest& value);
    static Result<BrowserKeyRequest> decode(const Json& value);
};

template <>
struct Codec<BrowserKeyPressRequest> {
    static Result<Json> encode(const BrowserKeyPressRequest& value);
    static Result<BrowserKeyPressRequest> decode(const Json& value);
};

template <>
struct Codec<BrowserMouseRequest> {
    static Result<Json> encode(const BrowserMouseRequest& value);
    static Result<BrowserMouseRequest> decode(const Json& value);
};

template <>
struct Codec<BrowserMouseGuardedRequest> {
    static Result<Json> encode(const BrowserMouseGuardedRequest& value);
    static Result<BrowserMouseGuardedRequest> decode(const Json& value);
};

template <>
struct Codec<BrowserNavigateRequest> {
    static Result<Json> encode(const BrowserNavigateRequest& value);
    static Result<BrowserNavigateRequest> decode(const Json& value);
};

template <>
struct Codec<BrowserReloadRequest> {
    static Result<Json> encode(const BrowserReloadRequest& value);
    static Result<BrowserReloadRequest> decode(const Json& value);
};

template <>
struct Codec<BrowserWheelRequest> {
    static Result<Json> encode(const BrowserWheelRequest& value);
    static Result<BrowserWheelRequest> decode(const Json& value);
};

template <>
struct Codec<BrowserWheelGuardedRequest> {
    static Result<Json> encode(const BrowserWheelGuardedRequest& value);
    static Result<BrowserWheelGuardedRequest> decode(const Json& value);
};

template <>
struct Codec<ClearHistoryRequest> {
    static Result<Json> encode(const ClearHistoryRequest& value);
    static Result<ClearHistoryRequest> decode(const Json& value);
};

template <>
struct Codec<ClearWindowTitleRequest> {
    static Result<Json> encode(const ClearWindowTitleRequest& value);
    static Result<ClearWindowTitleRequest> decode(const Json& value);
};

template <>
struct Codec<ClientFocusRequest> {
    static Result<Json> encode(const ClientFocusRequest& value);
    static Result<ClientFocusRequest> decode(const Json& value);
};

template <>
struct Codec<ClientFocusResult> {
    static Result<Json> encode(const ClientFocusResult& value);
    static Result<ClientFocusResult> decode(const Json& value);
};

template <>
struct Codec<ClosePaneRequest> {
    static Result<Json> encode(const ClosePaneRequest& value);
    static Result<ClosePaneRequest> decode(const Json& value);
};

template <>
struct Codec<CloseProviderManagedWorkspaceRequest> {
    static Result<Json> encode(const CloseProviderManagedWorkspaceRequest& value);
    static Result<CloseProviderManagedWorkspaceRequest> decode(const Json& value);
};

template <>
struct Codec<CloseScreenRequest> {
    static Result<Json> encode(const CloseScreenRequest& value);
    static Result<CloseScreenRequest> decode(const Json& value);
};

template <>
struct Codec<CloseSurfaceRequest> {
    static Result<Json> encode(const CloseSurfaceRequest& value);
    static Result<CloseSurfaceRequest> decode(const Json& value);
};

template <>
struct Codec<CloseTerminalRequest> {
    static Result<Json> encode(const CloseTerminalRequest& value);
    static Result<CloseTerminalRequest> decode(const Json& value);
};

template <>
struct Codec<CloseWorkspaceRequest> {
    static Result<Json> encode(const CloseWorkspaceRequest& value);
    static Result<CloseWorkspaceRequest> decode(const Json& value);
};

template <>
struct Codec<CopyRequest> {
    static Result<Json> encode(const CopyRequest& value);
    static Result<CopyRequest> decode(const Json& value);
};

template <>
struct Codec<CreateSurfaceWithReceiptRequest> {
    static Result<Json> encode(const CreateSurfaceWithReceiptRequest& value);
    static Result<CreateSurfaceWithReceiptRequest> decode(const Json& value);
};

template <>
struct Codec<CreateTerminalRequest> {
    static Result<Json> encode(const CreateTerminalRequest& value);
    static Result<CreateTerminalRequest> decode(const Json& value);
};

template <>
struct Codec<CreateWorkspaceRequest> {
    static Result<Json> encode(const CreateWorkspaceRequest& value);
    static Result<CreateWorkspaceRequest> decode(const Json& value);
};

template <>
struct Codec<DetachAttachedViewRequest> {
    static Result<Json> encode(const DetachAttachedViewRequest& value);
    static Result<DetachAttachedViewRequest> decode(const Json& value);
};

template <>
struct Codec<DetachClientRequest> {
    static Result<Json> encode(const DetachClientRequest& value);
    static Result<DetachClientRequest> decode(const Json& value);
};

template <>
struct Codec<ExportLayoutRequest> {
    static Result<Json> encode(const ExportLayoutRequest& value);
    static Result<ExportLayoutRequest> decode(const Json& value);
};

template <>
struct Codec<FocusDirectionRequest> {
    static Result<Json> encode(const FocusDirectionRequest& value);
    static Result<FocusDirectionRequest> decode(const Json& value);
};

template <>
struct Codec<FocusPaneRequest> {
    static Result<Json> encode(const FocusPaneRequest& value);
    static Result<FocusPaneRequest> decode(const Json& value);
};

template <>
struct Codec<GetBrowserProviderRequest> {
    static Result<Json> encode(const GetBrowserProviderRequest& value);
    static Result<GetBrowserProviderRequest> decode(const Json& value);
};

template <>
struct Codec<GetCellPixelsRequest> {
    static Result<Json> encode(const GetCellPixelsRequest& value);
    static Result<GetCellPixelsRequest> decode(const Json& value);
};

template <>
struct Codec<GetFrontendProjectionRequest> {
    static Result<Json> encode(const GetFrontendProjectionRequest& value);
    static Result<GetFrontendProjectionRequest> decode(const Json& value);
};

template <>
struct Codec<IdentifyRequest> {
    static Result<Json> encode(const IdentifyRequest& value);
    static Result<IdentifyRequest> decode(const Json& value);
};

template <>
struct Codec<IdsRequest> {
    static Result<Json> encode(const IdsRequest& value);
    static Result<IdsRequest> decode(const Json& value);
};

template <>
struct Codec<JournalFrontendEventRequest> {
    static Result<Json> encode(const JournalFrontendEventRequest& value);
    static Result<JournalFrontendEventRequest> decode(const Json& value);
};

template <>
struct Codec<JournalFrontendEventResult> {
    static Result<Json> encode(const JournalFrontendEventResult& value);
    static Result<JournalFrontendEventResult> decode(const Json& value);
};

template <>
struct Codec<ListAgentsRequest> {
    static Result<Json> encode(const ListAgentsRequest& value);
    static Result<ListAgentsRequest> decode(const Json& value);
};

template <>
struct Codec<ListClientsRequest> {
    static Result<Json> encode(const ListClientsRequest& value);
    static Result<ListClientsRequest> decode(const Json& value);
};

template <>
struct Codec<ListClientsResult> {
    static Result<Json> encode(const ListClientsResult& value);
    static Result<ListClientsResult> decode(const Json& value);
};

template <>
struct Codec<ListTerminalsRequest> {
    static Result<Json> encode(const ListTerminalsRequest& value);
    static Result<ListTerminalsRequest> decode(const Json& value);
};

template <>
struct Codec<ListWorkspacesRequest> {
    static Result<Json> encode(const ListWorkspacesRequest& value);
    static Result<ListWorkspacesRequest> decode(const Json& value);
};

template <>
struct Codec<MachineUsageRequest> {
    static Result<Json> encode(const MachineUsageRequest& value);
    static Result<MachineUsageRequest> decode(const Json& value);
};

template <>
struct Codec<MarkWorkspacesProviderManagedRequest> {
    static Result<Json> encode(const MarkWorkspacesProviderManagedRequest& value);
    static Result<MarkWorkspacesProviderManagedRequest> decode(const Json& value);
};

template <>
struct Codec<MintTerminalRendererRequest> {
    static Result<Json> encode(const MintTerminalRendererRequest& value);
    static Result<MintTerminalRendererRequest> decode(const Json& value);
};

template <>
struct Codec<MintTerminalRendererByTerminalRequest> {
    static Result<Json> encode(const MintTerminalRendererByTerminalRequest& value);
    static Result<MintTerminalRendererByTerminalRequest> decode(const Json& value);
};

template <>
struct Codec<MoveTabRequest> {
    static Result<Json> encode(const MoveTabRequest& value);
    static Result<MoveTabRequest> decode(const Json& value);
};

template <>
struct Codec<MoveTerminalRequest> {
    static Result<Json> encode(const MoveTerminalRequest& value);
    static Result<MoveTerminalRequest> decode(const Json& value);
};

template <>
struct Codec<MoveWorkspaceRequest> {
    static Result<Json> encode(const MoveWorkspaceRequest& value);
    static Result<MoveWorkspaceRequest> decode(const Json& value);
};

template <>
struct Codec<NewBrowserTabRequest> {
    static Result<Json> encode(const NewBrowserTabRequest& value);
    static Result<NewBrowserTabRequest> decode(const Json& value);
};

template <>
struct Codec<NewPaneRequest> {
    static Result<Json> encode(const NewPaneRequest& value);
    static Result<NewPaneRequest> decode(const Json& value);
};

template <>
struct Codec<NewPaneRightRequest> {
    static Result<Json> encode(const NewPaneRightRequest& value);
    static Result<NewPaneRightRequest> decode(const Json& value);
};

template <>
struct Codec<NewScreenRequest> {
    static Result<Json> encode(const NewScreenRequest& value);
    static Result<NewScreenRequest> decode(const Json& value);
};

template <>
struct Codec<NewTabRequest> {
    static Result<Json> encode(const NewTabRequest& value);
    static Result<NewTabRequest> decode(const Json& value);
};

template <>
struct Codec<NewWorkspaceRequest> {
    static Result<Json> encode(const NewWorkspaceRequest& value);
    static Result<NewWorkspaceRequest> decode(const Json& value);
};

template <>
struct Codec<NotifyRequest> {
    static Result<Json> encode(const NotifyRequest& value);
    static Result<NotifyRequest> decode(const Json& value);
};

template <>
struct Codec<PairingResponseRequest> {
    static Result<Json> encode(const PairingResponseRequest& value);
    static Result<PairingResponseRequest> decode(const Json& value);
};

template <>
struct Codec<PaneNeighborRequest> {
    static Result<Json> encode(const PaneNeighborRequest& value);
    static Result<PaneNeighborRequest> decode(const Json& value);
};

template <>
struct Codec<PingRequest> {
    static Result<Json> encode(const PingRequest& value);
    static Result<PingRequest> decode(const Json& value);
};

template <>
struct Codec<ProcessInfoRequest> {
    static Result<Json> encode(const ProcessInfoRequest& value);
    static Result<ProcessInfoRequest> decode(const Json& value);
};

template <>
struct Codec<PutFrontendProjectionRequest> {
    static Result<Json> encode(const PutFrontendProjectionRequest& value);
    static Result<PutFrontendProjectionRequest> decode(const Json& value);
};

template <>
struct Codec<ReadScreenRequest> {
    static Result<Json> encode(const ReadScreenRequest& value);
    static Result<ReadScreenRequest> decode(const Json& value);
};

template <>
struct Codec<ReadScrollbackRequest> {
    static Result<Json> encode(const ReadScrollbackRequest& value);
    static Result<ReadScrollbackRequest> decode(const Json& value);
};

template <>
struct Codec<RegisterBrowserProviderRequest> {
    static Result<Json> encode(const RegisterBrowserProviderRequest& value);
    static Result<RegisterBrowserProviderRequest> decode(const Json& value);
};

template <>
struct Codec<ReleaseAttachedViewSizeRequest> {
    static Result<Json> encode(const ReleaseAttachedViewSizeRequest& value);
    static Result<ReleaseAttachedViewSizeRequest> decode(const Json& value);
};

template <>
struct Codec<ReleaseSurfaceSizeRequest> {
    static Result<Json> encode(const ReleaseSurfaceSizeRequest& value);
    static Result<ReleaseSurfaceSizeRequest> decode(const Json& value);
};

template <>
struct Codec<ReloadConfigRequest> {
    static Result<Json> encode(const ReloadConfigRequest& value);
    static Result<ReloadConfigRequest> decode(const Json& value);
};

template <>
struct Codec<ReloadConfigResult> {
    static Result<Json> encode(const ReloadConfigResult& value);
    static Result<ReloadConfigResult> decode(const Json& value);
};

template <>
struct Codec<RenamePaneRequest> {
    static Result<Json> encode(const RenamePaneRequest& value);
    static Result<RenamePaneRequest> decode(const Json& value);
};

template <>
struct Codec<RenameProviderManagedWorkspaceRequest> {
    static Result<Json> encode(const RenameProviderManagedWorkspaceRequest& value);
    static Result<RenameProviderManagedWorkspaceRequest> decode(const Json& value);
};

template <>
struct Codec<RenameScreenRequest> {
    static Result<Json> encode(const RenameScreenRequest& value);
    static Result<RenameScreenRequest> decode(const Json& value);
};

template <>
struct Codec<RenameSurfaceRequest> {
    static Result<Json> encode(const RenameSurfaceRequest& value);
    static Result<RenameSurfaceRequest> decode(const Json& value);
};

template <>
struct Codec<RenameWorkspaceRequest> {
    static Result<Json> encode(const RenameWorkspaceRequest& value);
    static Result<RenameWorkspaceRequest> decode(const Json& value);
};

template <>
struct Codec<ReportAgentRequest> {
    static Result<Json> encode(const ReportAgentRequest& value);
    static Result<ReportAgentRequest> decode(const Json& value);
};

template <>
struct Codec<ReportFocusRequest> {
    static Result<Json> encode(const ReportFocusRequest& value);
    static Result<ReportFocusRequest> decode(const Json& value);
};

template <>
struct Codec<ResizeAttachedViewRequest> {
    static Result<Json> encode(const ResizeAttachedViewRequest& value);
    static Result<ResizeAttachedViewRequest> decode(const Json& value);
};

template <>
struct Codec<ResizeSurfaceRequest> {
    static Result<Json> encode(const ResizeSurfaceRequest& value);
    static Result<ResizeSurfaceRequest> decode(const Json& value);
};

template <>
struct Codec<ResolveTerminalRequest> {
    static Result<Json> encode(const ResolveTerminalRequest& value);
    static Result<ResolveTerminalRequest> decode(const Json& value);
};

template <>
struct Codec<RunRequest> {
    static Result<Json> encode(const RunRequest& value);
    static Result<RunRequest> decode(const Json& value);
};

template <>
struct Codec<ScrollSurfaceRequest> {
    static Result<Json> encode(const ScrollSurfaceRequest& value);
    static Result<ScrollSurfaceRequest> decode(const Json& value);
};

template <>
struct Codec<SelectScreenRequest> {
    static Result<Json> encode(const SelectScreenRequest& value);
    static Result<SelectScreenRequest> decode(const Json& value);
};

template <>
struct Codec<SelectTabRequest> {
    static Result<Json> encode(const SelectTabRequest& value);
    static Result<SelectTabRequest> decode(const Json& value);
};

template <>
struct Codec<SelectWorkspaceRequest> {
    static Result<Json> encode(const SelectWorkspaceRequest& value);
    static Result<SelectWorkspaceRequest> decode(const Json& value);
};

template <>
struct Codec<SendRequest> {
    static Result<Json> encode(const SendRequest& value);
    static Result<SendRequest> decode(const Json& value);
};

template <>
struct Codec<SendKeyRequest> {
    static Result<Json> encode(const SendKeyRequest& value);
    static Result<SendKeyRequest> decode(const Json& value);
};

template <>
struct Codec<SetCellPixelsRequest> {
    static Result<Json> encode(const SetCellPixelsRequest& value);
    static Result<SetCellPixelsRequest> decode(const Json& value);
};

template <>
struct Codec<SetClientInfoRequest> {
    static Result<Json> encode(const SetClientInfoRequest& value);
    static Result<SetClientInfoRequest> decode(const Json& value);
};

template <>
struct Codec<SetClientSizingRequest> {
    static Result<Json> encode(const SetClientSizingRequest& value);
    static Result<SetClientSizingRequest> decode(const Json& value);
};

template <>
struct Codec<SetDefaultColorsRequest> {
    static Result<Json> encode(const SetDefaultColorsRequest& value);
    static Result<SetDefaultColorsRequest> decode(const Json& value);
};

template <>
struct Codec<SetRatioRequest> {
    static Result<Json> encode(const SetRatioRequest& value);
    static Result<SetRatioRequest> decode(const Json& value);
};

template <>
struct Codec<SetSplitRatioRequest> {
    static Result<Json> encode(const SetSplitRatioRequest& value);
    static Result<SetSplitRatioRequest> decode(const Json& value);
};

template <>
struct Codec<SetViewportPaneWidthRequest> {
    static Result<Json> encode(const SetViewportPaneWidthRequest& value);
    static Result<SetViewportPaneWidthRequest> decode(const Json& value);
};

template <>
struct Codec<SetWindowTitleRequest> {
    static Result<Json> encode(const SetWindowTitleRequest& value);
    static Result<SetWindowTitleRequest> decode(const Json& value);
};

template <>
struct Codec<ShutdownDaemonRequest> {
    static Result<Json> encode(const ShutdownDaemonRequest& value);
    static Result<ShutdownDaemonRequest> decode(const Json& value);
};

template <>
struct Codec<SidebarPluginRequest> {
    static Result<Json> encode(const SidebarPluginRequest& value);
    static Result<SidebarPluginRequest> decode(const Json& value);
};

template <>
struct Codec<SplitRequest> {
    static Result<Json> encode(const SplitRequest& value);
    static Result<SplitRequest> decode(const Json& value);
};

template <>
struct Codec<SubscribeRequest> {
    static Result<Json> encode(const SubscribeRequest& value);
    static Result<SubscribeRequest> decode(const Json& value);
};

template <>
struct Codec<SwapPaneRequest> {
    static Result<Json> encode(const SwapPaneRequest& value);
    static Result<SwapPaneRequest> decode(const Json& value);
};

template <>
struct Codec<TerminalEventsRequest> {
    static Result<Json> encode(const TerminalEventsRequest& value);
    static Result<TerminalEventsRequest> decode(const Json& value);
};

template <>
struct Codec<UndoLayoutRequest> {
    static Result<Json> encode(const UndoLayoutRequest& value);
    static Result<UndoLayoutRequest> decode(const Json& value);
};

template <>
struct Codec<UnregisterBrowserProviderRequest> {
    static Result<Json> encode(const UnregisterBrowserProviderRequest& value);
    static Result<UnregisterBrowserProviderRequest> decode(const Json& value);
};

template <>
struct Codec<VtStateRequest> {
    static Result<Json> encode(const VtStateRequest& value);
    static Result<VtStateRequest> decode(const Json& value);
};

template <>
struct Codec<WaitForRequest> {
    static Result<Json> encode(const WaitForRequest& value);
    static Result<WaitForRequest> decode(const Json& value);
};

template <>
struct Codec<ZoomPaneRequest> {
    static Result<Json> encode(const ZoomPaneRequest& value);
    static Result<ZoomPaneRequest> decode(const Json& value);
};

template <>
struct Codec<AgentChangedEvent> {
    static Result<Json> encode(const AgentChangedEvent& value);
    static Result<AgentChangedEvent> decode(const Json& value);
};

template <>
struct Codec<BellEvent> {
    static Result<Json> encode(const BellEvent& value);
    static Result<BellEvent> decode(const Json& value);
};

template <>
struct Codec<BrowserStateEvent> {
    static Result<Json> encode(const BrowserStateEvent& value);
    static Result<BrowserStateEvent> decode(const Json& value);
};

template <>
struct Codec<ClientAttachedEvent> {
    static Result<Json> encode(const ClientAttachedEvent& value);
    static Result<ClientAttachedEvent> decode(const Json& value);
};

template <>
struct Codec<ClientChangedEvent> {
    static Result<Json> encode(const ClientChangedEvent& value);
    static Result<ClientChangedEvent> decode(const Json& value);
};

template <>
struct Codec<ClientDetachedEvent> {
    static Result<Json> encode(const ClientDetachedEvent& value);
    static Result<ClientDetachedEvent> decode(const Json& value);
};

template <>
struct Codec<ClientListInvalidatedEvent> {
    static Result<Json> encode(const ClientListInvalidatedEvent& value);
    static Result<ClientListInvalidatedEvent> decode(const Json& value);
};

template <>
struct Codec<ColorsChangedEvent> {
    static Result<Json> encode(const ColorsChangedEvent& value);
    static Result<ColorsChangedEvent> decode(const Json& value);
};

template <>
struct Codec<ConfigReloadRequestedEvent> {
    static Result<Json> encode(const ConfigReloadRequestedEvent& value);
    static Result<ConfigReloadRequestedEvent> decode(const Json& value);
};

template <>
struct Codec<DetachedEvent> {
    static Result<Json> encode(const DetachedEvent& value);
    static Result<DetachedEvent> decode(const Json& value);
};

template <>
struct Codec<EmptyEvent> {
    static Result<Json> encode(const EmptyEvent& value);
    static Result<EmptyEvent> decode(const Json& value);
};

template <>
struct Codec<FrameEvent> {
    static Result<Json> encode(const FrameEvent& value);
    static Result<FrameEvent> decode(const Json& value);
};

template <>
struct Codec<FrontendProjectionChangedEvent> {
    static Result<Json> encode(const FrontendProjectionChangedEvent& value);
    static Result<FrontendProjectionChangedEvent> decode(const Json& value);
};

template <>
struct Codec<GraphicsStatusEvent> {
    static Result<Json> encode(const GraphicsStatusEvent& value);
    static Result<GraphicsStatusEvent> decode(const Json& value);
};

template <>
struct Codec<LayoutChangedEvent> {
    static Result<Json> encode(const LayoutChangedEvent& value);
    static Result<LayoutChangedEvent> decode(const Json& value);
};

template <>
struct Codec<MachineUsageChangedEvent> {
    static Result<Json> encode(const MachineUsageChangedEvent& value);
    static Result<MachineUsageChangedEvent> decode(const Json& value);
};

template <>
struct Codec<NotificationEvent> {
    static Result<Json> encode(const NotificationEvent& value);
    static Result<NotificationEvent> decode(const Json& value);
};

template <>
struct Codec<OutputEvent> {
    static Result<Json> encode(const OutputEvent& value);
    static Result<OutputEvent> decode(const Json& value);
};

template <>
struct Codec<OverflowEvent> {
    static Result<Json> encode(const OverflowEvent& value);
    static Result<OverflowEvent> decode(const Json& value);
};

template <>
struct Codec<PairingRequestedEvent> {
    static Result<Json> encode(const PairingRequestedEvent& value);
    static Result<PairingRequestedEvent> decode(const Json& value);
};

template <>
struct Codec<PairingResolvedEvent> {
    static Result<Json> encode(const PairingResolvedEvent& value);
    static Result<PairingResolvedEvent> decode(const Json& value);
};

template <>
struct Codec<PaneAddedEvent> {
    static Result<Json> encode(const PaneAddedEvent& value);
    static Result<PaneAddedEvent> decode(const Json& value);
};

template <>
struct Codec<PaneClosedEvent> {
    static Result<Json> encode(const PaneClosedEvent& value);
    static Result<PaneClosedEvent> decode(const Json& value);
};

template <>
struct Codec<RenderDeltaEvent> {
    static Result<Json> encode(const RenderDeltaEvent& value);
    static Result<RenderDeltaEvent> decode(const Json& value);
};

template <>
struct Codec<RenderStateEvent> {
    static Result<Json> encode(const RenderStateEvent& value);
    static Result<RenderStateEvent> decode(const Json& value);
};

template <>
struct Codec<ResizedEvent> {
    static Result<Json> encode(const ResizedEvent& value);
    static Result<ResizedEvent> decode(const Json& value);
};

template <>
struct Codec<ScreenAddedEvent> {
    static Result<Json> encode(const ScreenAddedEvent& value);
    static Result<ScreenAddedEvent> decode(const Json& value);
};

template <>
struct Codec<ScreenClosedEvent> {
    static Result<Json> encode(const ScreenClosedEvent& value);
    static Result<ScreenClosedEvent> decode(const Json& value);
};

template <>
struct Codec<ScreenRenamedEvent> {
    static Result<Json> encode(const ScreenRenamedEvent& value);
    static Result<ScreenRenamedEvent> decode(const Json& value);
};

template <>
struct Codec<ScrollChangedEvent> {
    static Result<Json> encode(const ScrollChangedEvent& value);
    static Result<ScrollChangedEvent> decode(const Json& value);
};

template <>
struct Codec<StatusEvent> {
    static Result<Json> encode(const StatusEvent& value);
    static Result<StatusEvent> decode(const Json& value);
};

template <>
struct Codec<SurfaceExitedEvent> {
    static Result<Json> encode(const SurfaceExitedEvent& value);
    static Result<SurfaceExitedEvent> decode(const Json& value);
};

template <>
struct Codec<SurfaceOutputEvent> {
    static Result<Json> encode(const SurfaceOutputEvent& value);
    static Result<SurfaceOutputEvent> decode(const Json& value);
};

template <>
struct Codec<SurfaceResizeFailedEvent> {
    static Result<Json> encode(const SurfaceResizeFailedEvent& value);
    static Result<SurfaceResizeFailedEvent> decode(const Json& value);
};

template <>
struct Codec<SurfaceResizedEvent> {
    static Result<Json> encode(const SurfaceResizedEvent& value);
    static Result<SurfaceResizedEvent> decode(const Json& value);
};

template <>
struct Codec<TabAddedEvent> {
    static Result<Json> encode(const TabAddedEvent& value);
    static Result<TabAddedEvent> decode(const Json& value);
};

template <>
struct Codec<TabClosedEvent> {
    static Result<Json> encode(const TabClosedEvent& value);
    static Result<TabClosedEvent> decode(const Json& value);
};

template <>
struct Codec<TabRenamedEvent> {
    static Result<Json> encode(const TabRenamedEvent& value);
    static Result<TabRenamedEvent> decode(const Json& value);
};

template <>
struct Codec<TerminalRegistryChangedEvent> {
    static Result<Json> encode(const TerminalRegistryChangedEvent& value);
    static Result<TerminalRegistryChangedEvent> decode(const Json& value);
};

template <>
struct Codec<TitleChangedEvent> {
    static Result<Json> encode(const TitleChangedEvent& value);
    static Result<TitleChangedEvent> decode(const Json& value);
};

template <>
struct Codec<TreeChangedEvent> {
    static Result<Json> encode(const TreeChangedEvent& value);
    static Result<TreeChangedEvent> decode(const Json& value);
};

template <>
struct Codec<VtStateEvent> {
    static Result<Json> encode(const VtStateEvent& value);
    static Result<VtStateEvent> decode(const Json& value);
};

template <>
struct Codec<WindowTitleRequestedEvent> {
    static Result<Json> encode(const WindowTitleRequestedEvent& value);
    static Result<WindowTitleRequestedEvent> decode(const Json& value);
};

template <>
struct Codec<WorkspaceAddedEvent> {
    static Result<Json> encode(const WorkspaceAddedEvent& value);
    static Result<WorkspaceAddedEvent> decode(const Json& value);
};

template <>
struct Codec<WorkspaceClosedEvent> {
    static Result<Json> encode(const WorkspaceClosedEvent& value);
    static Result<WorkspaceClosedEvent> decode(const Json& value);
};

template <>
struct Codec<WorkspaceMovedEvent> {
    static Result<Json> encode(const WorkspaceMovedEvent& value);
    static Result<WorkspaceMovedEvent> decode(const Json& value);
};

template <>
struct Codec<WorkspaceRenamedEvent> {
    static Result<Json> encode(const WorkspaceRenamedEvent& value);
    static Result<WorkspaceRenamedEvent> decode(const Json& value);
};

template <>
struct Codec<CopyResultMode> {
    static Result<Json> encode(const CopyResultMode& value);
    static Result<CopyResultMode> decode(const Json& value);
};

template <>
struct Codec<DeclarativeLayoutLeaf> {
    static Result<Json> encode(const DeclarativeLayoutLeaf& value);
    static Result<DeclarativeLayoutLeaf> decode(const Json& value);
};

template <>
struct Codec<DeclarativeLayoutSplit> {
    static Result<Json> encode(const DeclarativeLayoutSplit& value);
    static Result<DeclarativeLayoutSplit> decode(const Json& value);
};

template <>
struct Codec<DeclarativeLayoutStack> {
    static Result<Json> encode(const DeclarativeLayoutStack& value);
    static Result<DeclarativeLayoutStack> decode(const Json& value);
};

template <>
struct Codec<FrontendJournalEventFocus> {
    static Result<Json> encode(const FrontendJournalEventFocus& value);
    static Result<FrontendJournalEventFocus> decode(const Json& value);
};

template <>
struct Codec<FrontendJournalEventResize> {
    static Result<Json> encode(const FrontendJournalEventResize& value);
    static Result<FrontendJournalEventResize> decode(const Json& value);
};

template <>
struct Codec<FrontendJournalEventViewport> {
    static Result<Json> encode(const FrontendJournalEventViewport& value);
    static Result<FrontendJournalEventViewport> decode(const Json& value);
};

template <>
struct Codec<IdMappingKind> {
    static Result<Json> encode(const IdMappingKind& value);
    static Result<IdMappingKind> decode(const Json& value);
};

template <>
struct Codec<LayoutLeaf> {
    static Result<Json> encode(const LayoutLeaf& value);
    static Result<LayoutLeaf> decode(const Json& value);
};

template <>
struct Codec<LayoutSplit> {
    static Result<Json> encode(const LayoutSplit& value);
    static Result<LayoutSplit> decode(const Json& value);
};

template <>
struct Codec<LayoutStack> {
    static Result<Json> encode(const LayoutStack& value);
    static Result<LayoutStack> decode(const Json& value);
};

template <>
struct Codec<TabBrowserSource> {
    static Result<Json> encode(const TabBrowserSource& value);
    static Result<TabBrowserSource> decode(const Json& value);
};

template <>
struct Codec<TabBrowserStatus> {
    static Result<Json> encode(const TabBrowserStatus& value);
    static Result<TabBrowserStatus> decode(const Json& value);
};

template <>
struct Codec<TabKind> {
    static Result<Json> encode(const TabKind& value);
    static Result<TabKind> decode(const Json& value);
};

template <>
struct Codec<TerminalExitOutcomeExit> {
    static Result<Json> encode(const TerminalExitOutcomeExit& value);
    static Result<TerminalExitOutcomeExit> decode(const Json& value);
};

template <>
struct Codec<TerminalExitOutcomeSignal> {
    static Result<Json> encode(const TerminalExitOutcomeSignal& value);
    static Result<TerminalExitOutcomeSignal> decode(const Json& value);
};

template <>
struct Codec<TerminalExitOutcomeUnknown> {
    static Result<Json> encode(const TerminalExitOutcomeUnknown& value);
    static Result<TerminalExitOutcomeUnknown> decode(const Json& value);
};

template <>
struct Codec<AttachSurfaceRequestMode> {
    static Result<Json> encode(const AttachSurfaceRequestMode& value);
    static Result<AttachSurfaceRequestMode> decode(const Json& value);
};

template <>
struct Codec<BrowserKeyRequestKind> {
    static Result<Json> encode(const BrowserKeyRequestKind& value);
    static Result<BrowserKeyRequestKind> decode(const Json& value);
};

template <>
struct Codec<BrowserMouseRequestKind> {
    static Result<Json> encode(const BrowserMouseRequestKind& value);
    static Result<BrowserMouseRequestKind> decode(const Json& value);
};

template <>
struct Codec<BrowserMouseGuardedRequestKind> {
    static Result<Json> encode(const BrowserMouseGuardedRequestKind& value);
    static Result<BrowserMouseGuardedRequestKind> decode(const Json& value);
};

template <>
struct Codec<CopyRequestMode> {
    static Result<Json> encode(const CopyRequestMode& value);
    static Result<CopyRequestMode> decode(const Json& value);
};

template <>
struct Codec<IdsRequestKind> {
    static Result<Json> encode(const IdsRequestKind& value);
    static Result<IdsRequestKind> decode(const Json& value);
};

template <>
struct Codec<SubscribeRequestTreeEvents> {
    static Result<Json> encode(const SubscribeRequestTreeEvents& value);
    static Result<SubscribeRequestTreeEvents> decode(const Json& value);
};

template <>
struct Codec<ZoomPaneRequestMode> {
    static Result<Json> encode(const ZoomPaneRequestMode& value);
    static Result<ZoomPaneRequestMode> decode(const Json& value);
};

template <>
struct Codec<BrowserStateEventStatus> {
    static Result<Json> encode(const BrowserStateEventStatus& value);
    static Result<BrowserStateEventStatus> decode(const Json& value);
};

template <>
struct Codec<ClientAttachedEventTransport> {
    static Result<Json> encode(const ClientAttachedEventTransport& value);
    static Result<ClientAttachedEventTransport> decode(const Json& value);
};

template <>
struct Codec<GraphicsStatusEventKind> {
    static Result<Json> encode(const GraphicsStatusEventKind& value);
    static Result<GraphicsStatusEventKind> decode(const Json& value);
};

}  // namespace cmux::raw
