#include <cmux/client.hpp>
#include <cmux/raw/client.hpp>
#include <cmux/version.hpp>

#include <type_traits>
#include <utility>

static_assert(std::is_same_v<
              decltype(std::declval<cmux::Workspace&>().refresh()),
              cmux::Result<cmux::WorkspaceSnapshot>>);
static_assert(std::is_same_v<
              decltype(std::declval<cmux::Terminal&>().wait_exit()),
              cmux::Result<cmux::TerminalWaitExitResult>>);
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
    auto split_params = pane_split.to_params();

    cmux::CreateTerminalTabOptions terminal_create;
    terminal_create.correlation_key = "consumer-terminal";
    auto terminal_params = terminal_create.to_params();

    cmux::CreateBrowserTabOptions browser_create("https://example.com");
    browser_create.correlation_key = "consumer-browser";
    auto browser_params = browser_create.to_params();

    cmux::raw::IdentifyRequest raw_request;
    return selector.wire() != "name:current" ||
                   !workspace_params || !run_params || !screen_params ||
                   !pane_params || !split_params || !terminal_params ||
                   !browser_params ||
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
                   !(raw_request == cmux::raw::IdentifyRequest{}) ||
                   cmux::kSdkVersion != "1.0.0"
               ? 1
               : 0;
}
