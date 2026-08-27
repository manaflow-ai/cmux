#include <cmux/client.hpp>
#include <cmux/raw/client.hpp>
#include <cmux/version.hpp>

#include <cstdint>
#include <optional>
#include <type_traits>
#include <utility>

static_assert(std::is_same_v<
              decltype(std::declval<cmux::Workspace&>().refresh()),
              cmux::Result<cmux::WorkspaceSnapshot>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::Terminal&>().wait_exit()),
              cmux::Result<cmux::TerminalWaitExitResult>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::Terminal&>().read_history(
                  std::declval<cmux::TerminalHistoryOptions>())),
              cmux::Result<cmux::TerminalHistoryResult>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::Terminal&>().attach(
                  std::declval<cmux::TerminalAttachOptions>(),
                  std::declval<cmux::CallOptions>())),
              cmux::Result<cmux::TerminalAttachmentStream>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::BrowserAttachFrame>()
                           .pointer_frame_seq),
              std::optional<std::uint64_t>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::Browser&>().mouse(
                  std::declval<cmux::Json::Object>(),
                  std::declval<std::uint64_t>(),
                  std::declval<cmux::MutationOptions>())),
              cmux::Result<cmux::MutationResult<cmux::EmptyResult>>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::Browser&>().wheel(
                  std::declval<double>(),
                  std::declval<double>(),
                  std::declval<double>(),
                  std::declval<double>(),
                  std::declval<std::uint64_t>(),
                  std::declval<cmux::MutationOptions>())),
              cmux::Result<cmux::MutationResult<cmux::EmptyResult>>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::Workspace&>().run(
                  std::declval<cmux::RunOptions>(),
                  std::declval<cmux::MutationOptions>(),
                  std::declval<cmux::CallOptions>())),
              cmux::Result<
                  cmux::MutationResult<cmux::CreatedTerminalPath>>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::Session&>().notifications()),
              cmux::Result<std::vector<cmux::NotificationSnapshot>>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::Session&>().create_notification(
                  std::declval<cmux::NotificationCreateOptions>(),
                  std::declval<cmux::MutationOptions>())),
              cmux::Result<
                  cmux::MutationResult<cmux::NotificationSnapshot>>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::Session&>().report_agent(
                  std::declval<cmux::AgentReportOptions>(),
                  std::declval<cmux::MutationOptions>())),
              cmux::Result<cmux::MutationResult<cmux::AgentSnapshot>>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::raw::Client&>().identify()),
              cmux::Result<cmux::raw::IdentifyResult>>);
static_assert(!std::is_copy_constructible_v<cmux::SessionEventStream>);
static_assert(std::is_nothrow_move_constructible_v<cmux::SessionEventStream>);

int main() {
    auto id = cmux::WorkspaceId::parse(
        "ws_0123456789abcdef0123456789abcdef");
    if (!id) {
        return 1;
    }
    const auto selector =
        cmux::Selector<cmux::WorkspaceId>::exact_name("current");
    auto command = cmux::RunCommand::exact({"cargo", "test"});
    if (!command || command.value().argv().size() != 2) {
        return 1;
    }

    cmux::CreateWorkspaceOptions workspace_create;
    workspace_create.correlation_key = "consumer-workspace";
    auto workspace_params = workspace_create.to_params();

    cmux::RunOptions run(std::move(command).value());
    run.correlation_key = "consumer-run";
    auto run_params = run.to_params();

    cmux::CreateScreenOptions screen_create;
    screen_create.correlation_key = "consumer-screen";
    auto screen_params = screen_create.to_params();

    cmux::CreatePaneOptions pane_create;
    pane_create.correlation_key = "consumer-pane";
    auto pane_params = pane_create.to_params();

    cmux::SplitPaneOptions pane_split(cmux::PaneDirection::right);
    pane_split.correlation_key = "consumer-split";
    pane_split.viewport_width = 0.5;
    auto split_params = pane_split.to_params();

    cmux::CreateTerminalTabOptions terminal_create;
    terminal_create.correlation_key = "consumer-terminal";
    auto terminal_params = terminal_create.to_params();

    cmux::CreateBrowserTabOptions browser_create("https://example.com");
    browser_create.correlation_key = "consumer-browser";
    auto browser_params = browser_create.to_params();

    cmux::TerminalHistoryOptions history;
    history.before = 50;
    history.limit = 100;
    history.styled = true;
    auto history_params = history.to_params();

    cmux::TerminalAttachOptions attach;
    attach.cols = 120;
    attach.rows = 40;
    attach.read_only = true;
    auto attach_params = attach.to_params();

    auto terminal_id = cmux::TerminalId::parse(
        "term_0123456789abcdef0123456789abcdef");
    if (!terminal_id) {
        return 1;
    }
    cmux::NotificationCreateOptions notification("build", "complete");
    notification.level = cmux::NotificationLevel::info;
    notification.terminal_id = terminal_id.value();
    auto notification_params = notification.to_params();

    cmux::AgentReportOptions agent(
        terminal_id.value(),
        cmux::AgentState::working,
        cmux::AgentReportSource::socket);
    agent.source_session = "consumer";
    auto agent_params = agent.to_params();

    cmux::raw::IdentifyRequest raw_request;
    return selector.wire() != "name:current" ||
                   !workspace_params || !run_params || !screen_params ||
                   !pane_params || !split_params || !terminal_params ||
                   !browser_params || !history_params || !attach_params ||
                   !notification_params || !agent_params ||
                   workspace_params.value()
                           .at("correlation_key")
                           .as_string()
                           .value() != "consumer-workspace" ||
                   run_params.value()
                           .at("correlation_key")
                           .as_string()
                           .value() != "consumer-run" ||
                   screen_params.value()
                           .at("correlation_key")
                           .as_string()
                           .value() != "consumer-screen" ||
                   pane_params.value()
                           .at("correlation_key")
                           .as_string()
                           .value() != "consumer-pane" ||
                   split_params.value()
                           .at("correlation_key")
                           .as_string()
                           .value() != "consumer-split" ||
                   terminal_params.value()
                           .at("correlation_key")
                           .as_string()
                           .value() != "consumer-terminal" ||
                   browser_params.value()
                           .at("correlation_key")
                           .as_string()
                           .value() != "consumer-browser" ||
                   history_params.value()
                           .at("before")
                           .as_string()
                           .value() != "50" ||
                   history_params.value()
                           .at("limit")
                           .as_uint64()
                           .value() != 100 ||
                   attach_params.value()
                           .at("cols")
                           .as_uint64()
                           .value() != 120 ||
                   !attach_params.value()
                            .at("read_only")
                            .as_bool()
                            .value() ||
                   notification_params.value()
                           .at("level")
                           .as_string()
                           .value() != "info" ||
                   agent_params.value()
                           .at("source")
                           .as_string()
                           .value() != "socket" ||
                   !(raw_request == cmux::raw::IdentifyRequest{}) ||
                   cmux::kSdkVersion != "1.0.0"
               ? 1
               : 0;
}
