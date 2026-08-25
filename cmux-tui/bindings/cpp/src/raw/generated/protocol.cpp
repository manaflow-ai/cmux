// Generated from cmux-tui/spec/sdk-schema.json. Do not edit.
#include "cmux/raw/generated/commands.hpp"

#include <array>
#include <utility>

namespace cmux::raw {

Result<Json> Codec<AgentRecord>::encode(const AgentRecord& value) {
    (void)value;
    Json::Object object;
    if (value.session) {
        auto encoded = encode_value(*value.session);
        if (!encoded) return std::move(encoded).error();
        object.emplace("session", std::move(encoded).value());
    } else {
        object.emplace("session", Json(nullptr));
    }
    auto encoded_source = encode_value(value.source);
    if (!encoded_source) return std::move(encoded_source).error();
    object.emplace("source", std::move(encoded_source).value());
    auto encoded_state = encode_value(value.state);
    if (!encoded_state) return std::move(encoded_state).error();
    object.emplace("state", std::move(encoded_state).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    auto encoded_updated_at_ms = encode_value(value.updated_at_ms);
    if (!encoded_updated_at_ms) return std::move(encoded_updated_at_ms).error();
    object.emplace("updated_at_ms", std::move(encoded_updated_at_ms).value());
    return Json(std::move(object));
}

Result<AgentRecord> Codec<AgentRecord>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    AgentRecord result{};
    const Json* field_session = value.find("session");
    if (!field_session) {
        return make_error(ErrorCode::decode, "missing required field 'session'");
    }
    if (field_session) {
        if (field_session->is_null()) {
            result.session.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_session);
            if (!decoded) return std::move(decoded).error();
            result.session = std::move(decoded).value();
        }
    }
    const Json* field_source = value.find("source");
    if (!field_source) {
        return make_error(ErrorCode::decode, "missing required field 'source'");
    }
    if (field_source) {
        auto decoded = decode_value<AgentSource>(*field_source);
        if (!decoded) return std::move(decoded).error();
        result.source = std::move(decoded).value();
    }
    const Json* field_state = value.find("state");
    if (!field_state) {
        return make_error(ErrorCode::decode, "missing required field 'state'");
    }
    if (field_state) {
        auto decoded = decode_value<AgentState>(*field_state);
        if (!decoded) return std::move(decoded).error();
        result.state = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_updated_at_ms = value.find("updated_at_ms");
    if (!field_updated_at_ms) {
        return make_error(ErrorCode::decode, "missing required field 'updated_at_ms'");
    }
    if (field_updated_at_ms) {
        auto decoded = decode_value<std::uint64_t>(*field_updated_at_ms);
        if (!decoded) return std::move(decoded).error();
        result.updated_at_ms = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<AgentReportSource>::encode(const AgentReportSource& value) {
    switch (value) {
        case AgentReportSource::socket: return Json(std::string("socket"));
        case AgentReportSource::hook: return Json(std::string("hook"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<AgentReportSource> Codec<AgentReportSource>::decode(const Json& value) {
    if (value == Json(std::string("socket"))) return AgentReportSource::socket;
    if (value == Json(std::string("hook"))) return AgentReportSource::hook;
    return make_error(ErrorCode::decode, "unknown AgentReportSource value");
}

Result<Json> Codec<AgentSource>::encode(const AgentSource& value) {
    switch (value) {
        case AgentSource::detected: return Json(std::string("detected"));
        case AgentSource::socket: return Json(std::string("socket"));
        case AgentSource::hook: return Json(std::string("hook"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<AgentSource> Codec<AgentSource>::decode(const Json& value) {
    if (value == Json(std::string("detected"))) return AgentSource::detected;
    if (value == Json(std::string("socket"))) return AgentSource::socket;
    if (value == Json(std::string("hook"))) return AgentSource::hook;
    return make_error(ErrorCode::decode, "unknown AgentSource value");
}

Result<Json> Codec<AgentState>::encode(const AgentState& value) {
    switch (value) {
        case AgentState::working: return Json(std::string("working"));
        case AgentState::blocked: return Json(std::string("blocked"));
        case AgentState::idle: return Json(std::string("idle"));
        case AgentState::done: return Json(std::string("done"));
        case AgentState::unknown: return Json(std::string("unknown"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<AgentState> Codec<AgentState>::decode(const Json& value) {
    if (value == Json(std::string("working"))) return AgentState::working;
    if (value == Json(std::string("blocked"))) return AgentState::blocked;
    if (value == Json(std::string("idle"))) return AgentState::idle;
    if (value == Json(std::string("done"))) return AgentState::done;
    if (value == Json(std::string("unknown"))) return AgentState::unknown;
    return make_error(ErrorCode::decode, "unknown AgentState value");
}

Result<Json> Codec<AppliedPane>::encode(const AppliedPane& value) {
    (void)value;
    Json::Object object;
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<AppliedPane> Codec<AppliedPane>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    AppliedPane result{};
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ApplyLayoutResult>::encode(const ApplyLayoutResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_panes = encode_value(value.panes);
    if (!encoded_panes) return std::move(encoded_panes).error();
    object.emplace("panes", std::move(encoded_panes).value());
    auto encoded_screen = encode_value(value.screen);
    if (!encoded_screen) return std::move(encoded_screen).error();
    object.emplace("screen", std::move(encoded_screen).value());
    return Json(std::move(object));
}

Result<ApplyLayoutResult> Codec<ApplyLayoutResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ApplyLayoutResult result{};
    const Json* field_panes = value.find("panes");
    if (!field_panes) {
        return make_error(ErrorCode::decode, "missing required field 'panes'");
    }
    if (field_panes) {
        auto decoded = decode_value<std::vector<AppliedPane>>(*field_panes);
        if (!decoded) return std::move(decoded).error();
        result.panes = std::move(decoded).value();
    }
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        auto decoded = decode_value<Id>(*field_screen);
        if (!decoded) return std::move(decoded).error();
        result.screen = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<AttachedViewOutcomeResult>::encode(const AttachedViewOutcomeResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_outcome = encode_value(value.outcome);
    if (!encoded_outcome) return std::move(encoded_outcome).error();
    object.emplace("outcome", std::move(encoded_outcome).value());
    return Json(std::move(object));
}

Result<AttachedViewOutcomeResult> Codec<AttachedViewOutcomeResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    AttachedViewOutcomeResult result{};
    const Json* field_outcome = value.find("outcome");
    if (!field_outcome) {
        return make_error(ErrorCode::decode, "missing required field 'outcome'");
    }
    if (field_outcome) {
        auto decoded = decode_value<ViewAttachmentOutcome>(*field_outcome);
        if (!decoded) return std::move(decoded).error();
        result.outcome = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<AttachedViewResizeResult>::encode(const AttachedViewResizeResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_accepted = encode_value(value.accepted);
    if (!encoded_accepted) return std::move(encoded_accepted).error();
    object.emplace("accepted", std::move(encoded_accepted).value());
    auto encoded_outcome = encode_value(value.outcome);
    if (!encoded_outcome) return std::move(encoded_outcome).error();
    object.emplace("outcome", std::move(encoded_outcome).value());
    if (value.reservation_id) {
        auto encoded = encode_value(*value.reservation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("reservation_id", std::move(encoded).value());
    } else {
        object.emplace("reservation_id", Json(nullptr));
    }
    return Json(std::move(object));
}

Result<AttachedViewResizeResult> Codec<AttachedViewResizeResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    AttachedViewResizeResult result{};
    const Json* field_accepted = value.find("accepted");
    if (!field_accepted) {
        return make_error(ErrorCode::decode, "missing required field 'accepted'");
    }
    if (field_accepted) {
        auto decoded = decode_value<bool>(*field_accepted);
        if (!decoded) return std::move(decoded).error();
        result.accepted = std::move(decoded).value();
    }
    const Json* field_outcome = value.find("outcome");
    if (!field_outcome) {
        return make_error(ErrorCode::decode, "missing required field 'outcome'");
    }
    if (field_outcome) {
        auto decoded = decode_value<ViewAttachmentOutcome>(*field_outcome);
        if (!decoded) return std::move(decoded).error();
        result.outcome = std::move(decoded).value();
    }
    const Json* field_reservation_id = value.find("reservation_id");
    if (!field_reservation_id) {
        return make_error(ErrorCode::decode, "missing required field 'reservation_id'");
    }
    if (field_reservation_id) {
        if (field_reservation_id->is_null()) {
            result.reservation_id.reset();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_reservation_id);
            if (!decoded) return std::move(decoded).error();
            result.reservation_id = std::move(decoded).value();
        }
    }
    return result;
}

Result<Json> Codec<Base64>::encode(const Base64& value) {
    return encode_value(value.value);
}

Result<Base64> Codec<Base64>::decode(const Json& value) {
    auto decoded = decode_value<std::string>(value);
    if (!decoded) return std::move(decoded).error();
    return Base64{std::move(decoded).value()};
}

Result<Json> Codec<BrowserFrame>::encode(const BrowserFrame& value) {
    (void)value;
    Json::Object object;
    auto encoded_data = encode_value(value.data);
    if (!encoded_data) return std::move(encoded_data).error();
    object.emplace("data", std::move(encoded_data).value());
    auto encoded_height = encode_value(value.height);
    if (!encoded_height) return std::move(encoded_height).error();
    object.emplace("height", std::move(encoded_height).value());
    auto encoded_seq = encode_value(value.seq);
    if (!encoded_seq) return std::move(encoded_seq).error();
    object.emplace("seq", std::move(encoded_seq).value());
    auto encoded_width = encode_value(value.width);
    if (!encoded_width) return std::move(encoded_width).error();
    object.emplace("width", std::move(encoded_width).value());
    return Json(std::move(object));
}

Result<BrowserFrame> Codec<BrowserFrame>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserFrame result{};
    const Json* field_data = value.find("data");
    if (!field_data) {
        return make_error(ErrorCode::decode, "missing required field 'data'");
    }
    if (field_data) {
        auto decoded = decode_value<Base64>(*field_data);
        if (!decoded) return std::move(decoded).error();
        result.data = std::move(decoded).value();
    }
    const Json* field_height = value.find("height");
    if (!field_height) {
        return make_error(ErrorCode::decode, "missing required field 'height'");
    }
    if (field_height) {
        auto decoded = decode_value<std::uint32_t>(*field_height);
        if (!decoded) return std::move(decoded).error();
        result.height = std::move(decoded).value();
    }
    const Json* field_seq = value.find("seq");
    if (!field_seq) {
        return make_error(ErrorCode::decode, "missing required field 'seq'");
    }
    if (field_seq) {
        auto decoded = decode_value<std::uint64_t>(*field_seq);
        if (!decoded) return std::move(decoded).error();
        result.seq = std::move(decoded).value();
    }
    const Json* field_width = value.find("width");
    if (!field_width) {
        return make_error(ErrorCode::decode, "missing required field 'width'");
    }
    if (field_width) {
        auto decoded = decode_value<std::uint32_t>(*field_width);
        if (!decoded) return std::move(decoded).error();
        result.width = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserProviderAuthentication>::encode(const BrowserProviderAuthentication& value) {
    switch (value) {
        case BrowserProviderAuthentication::none: return Json(std::string("none"));
        case BrowserProviderAuthentication::bearer: return Json(std::string("bearer"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<BrowserProviderAuthentication> Codec<BrowserProviderAuthentication>::decode(const Json& value) {
    if (value == Json(std::string("none"))) return BrowserProviderAuthentication::none;
    if (value == Json(std::string("bearer"))) return BrowserProviderAuthentication::bearer;
    return make_error(ErrorCode::decode, "unknown BrowserProviderAuthentication value");
}

Result<Json> Codec<BrowserProviderSnapshot>::encode(const BrowserProviderSnapshot& value) {
    (void)value;
    Json::Object object;
    if (value.authentication) {
        auto encoded = encode_value(*value.authentication);
        if (!encoded) return std::move(encoded).error();
        object.emplace("authentication", std::move(encoded).value());
    }
    auto encoded_available = encode_value(value.available);
    if (!encoded_available) return std::move(encoded_available).error();
    object.emplace("available", std::move(encoded_available).value());
    if (value.clients) {
        auto encoded = encode_value(*value.clients);
        if (!encoded) return std::move(encoded).error();
        object.emplace("clients", std::move(encoded).value());
    }
    if (value.endpoint) {
        auto encoded = encode_value(*value.endpoint);
        if (!encoded) return std::move(encoded).error();
        object.emplace("endpoint", std::move(encoded).value());
    }
    if (value.provider_id) {
        auto encoded = encode_value(*value.provider_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("provider_id", std::move(encoded).value());
    }
    auto encoded_revision = encode_value(value.revision);
    if (!encoded_revision) return std::move(encoded_revision).error();
    object.emplace("revision", std::move(encoded_revision).value());
    auto encoded_targets = encode_value(value.targets);
    if (!encoded_targets) return std::move(encoded_targets).error();
    object.emplace("targets", std::move(encoded_targets).value());
    return Json(std::move(object));
}

Result<BrowserProviderSnapshot> Codec<BrowserProviderSnapshot>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserProviderSnapshot result{};
    const Json* field_authentication = value.find("authentication");
    if (field_authentication) {
        auto decoded = decode_value<BrowserProviderAuthentication>(*field_authentication);
        if (!decoded) return std::move(decoded).error();
        result.authentication = std::move(decoded).value();
    }
    const Json* field_available = value.find("available");
    if (!field_available) {
        return make_error(ErrorCode::decode, "missing required field 'available'");
    }
    if (field_available) {
        auto decoded = decode_value<bool>(*field_available);
        if (!decoded) return std::move(decoded).error();
        result.available = std::move(decoded).value();
    }
    const Json* field_clients = value.find("clients");
    if (field_clients) {
        auto decoded = decode_value<std::uint64_t>(*field_clients);
        if (!decoded) return std::move(decoded).error();
        result.clients = std::move(decoded).value();
    }
    const Json* field_endpoint = value.find("endpoint");
    if (field_endpoint) {
        auto decoded = decode_value<std::string>(*field_endpoint);
        if (!decoded) return std::move(decoded).error();
        result.endpoint = std::move(decoded).value();
    }
    const Json* field_provider_id = value.find("provider_id");
    if (field_provider_id) {
        auto decoded = decode_value<std::string>(*field_provider_id);
        if (!decoded) return std::move(decoded).error();
        result.provider_id = std::move(decoded).value();
    }
    const Json* field_revision = value.find("revision");
    if (!field_revision) {
        return make_error(ErrorCode::decode, "missing required field 'revision'");
    }
    if (field_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_revision);
        if (!decoded) return std::move(decoded).error();
        result.revision = std::move(decoded).value();
    }
    const Json* field_targets = value.find("targets");
    if (!field_targets) {
        return make_error(ErrorCode::decode, "missing required field 'targets'");
    }
    if (field_targets) {
        auto decoded = decode_value<std::vector<BrowserProviderTarget>>(*field_targets);
        if (!decoded) return std::move(decoded).error();
        result.targets = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserProviderTarget>::encode(const BrowserProviderTarget& value) {
    (void)value;
    Json::Object object;
    auto encoded_tab_id = encode_value(value.tab_id);
    if (!encoded_tab_id) return std::move(encoded_tab_id).error();
    object.emplace("tab_id", std::move(encoded_tab_id).value());
    auto encoded_target_id = encode_value(value.target_id);
    if (!encoded_target_id) return std::move(encoded_target_id).error();
    object.emplace("target_id", std::move(encoded_target_id).value());
    return Json(std::move(object));
}

Result<BrowserProviderTarget> Codec<BrowserProviderTarget>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserProviderTarget result{};
    const Json* field_tab_id = value.find("tab_id");
    if (!field_tab_id) {
        return make_error(ErrorCode::decode, "missing required field 'tab_id'");
    }
    if (field_tab_id) {
        auto decoded = decode_value<std::string>(*field_tab_id);
        if (!decoded) return std::move(decoded).error();
        result.tab_id = std::move(decoded).value();
    }
    const Json* field_target_id = value.find("target_id");
    if (!field_target_id) {
        return make_error(ErrorCode::decode, "missing required field 'target_id'");
    }
    if (field_target_id) {
        auto decoded = decode_value<std::string>(*field_target_id);
        if (!decoded) return std::move(decoded).error();
        result.target_id = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserProviderUnregisterResult>::encode(const BrowserProviderUnregisterResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_removed = encode_value(value.removed);
    if (!encoded_removed) return std::move(encoded_removed).error();
    object.emplace("removed", std::move(encoded_removed).value());
    return Json(std::move(object));
}

Result<BrowserProviderUnregisterResult> Codec<BrowserProviderUnregisterResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserProviderUnregisterResult result{};
    const Json* field_removed = value.find("removed");
    if (!field_removed) {
        return make_error(ErrorCode::decode, "missing required field 'removed'");
    }
    if (field_removed) {
        auto decoded = decode_value<bool>(*field_removed);
        if (!decoded) return std::move(decoded).error();
        result.removed = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<CellPixelFailure>::encode(const CellPixelFailure& value) {
    (void)value;
    Json::Object object;
    auto encoded_error = encode_value(value.error);
    if (!encoded_error) return std::move(encoded_error).error();
    object.emplace("error", std::move(encoded_error).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<CellPixelFailure> Codec<CellPixelFailure>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    CellPixelFailure result{};
    const Json* field_error = value.find("error");
    if (!field_error) {
        return make_error(ErrorCode::decode, "missing required field 'error'");
    }
    if (field_error) {
        auto decoded = decode_value<std::string>(*field_error);
        if (!decoded) return std::move(decoded).error();
        result.error = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<CellPixelResize>::encode(const CellPixelResize& value) {
    (void)value;
    Json::Object object;
    auto encoded_cols = encode_value(value.cols);
    if (!encoded_cols) return std::move(encoded_cols).error();
    object.emplace("cols", std::move(encoded_cols).value());
    auto encoded_reservation_id = encode_value(value.reservation_id);
    if (!encoded_reservation_id) return std::move(encoded_reservation_id).error();
    object.emplace("reservation_id", std::move(encoded_reservation_id).value());
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<CellPixelResize> Codec<CellPixelResize>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    CellPixelResize result{};
    const Json* field_cols = value.find("cols");
    if (!field_cols) {
        return make_error(ErrorCode::decode, "missing required field 'cols'");
    }
    if (field_cols) {
        auto decoded = decode_value<std::uint16_t>(*field_cols);
        if (!decoded) return std::move(decoded).error();
        result.cols = std::move(decoded).value();
    }
    const Json* field_reservation_id = value.find("reservation_id");
    if (!field_reservation_id) {
        return make_error(ErrorCode::decode, "missing required field 'reservation_id'");
    }
    if (field_reservation_id) {
        auto decoded = decode_value<std::uint64_t>(*field_reservation_id);
        if (!decoded) return std::move(decoded).error();
        result.reservation_id = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::uint16_t>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<CellPixelSurface>::encode(const CellPixelSurface& value) {
    (void)value;
    Json::Object object;
    auto encoded_height_px = encode_value(value.height_px);
    if (!encoded_height_px) return std::move(encoded_height_px).error();
    object.emplace("height_px", std::move(encoded_height_px).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    auto encoded_width_px = encode_value(value.width_px);
    if (!encoded_width_px) return std::move(encoded_width_px).error();
    object.emplace("width_px", std::move(encoded_width_px).value());
    return Json(std::move(object));
}

Result<CellPixelSurface> Codec<CellPixelSurface>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    CellPixelSurface result{};
    const Json* field_height_px = value.find("height_px");
    if (!field_height_px) {
        return make_error(ErrorCode::decode, "missing required field 'height_px'");
    }
    if (field_height_px) {
        auto decoded = decode_value<std::uint16_t>(*field_height_px);
        if (!decoded) return std::move(decoded).error();
        result.height_px = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_width_px = value.find("width_px");
    if (!field_width_px) {
        return make_error(ErrorCode::decode, "missing required field 'width_px'");
    }
    if (field_width_px) {
        auto decoded = decode_value<std::uint16_t>(*field_width_px);
        if (!decoded) return std::move(decoded).error();
        result.width_px = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ClientInfo>::encode(const ClientInfo& value) {
    (void)value;
    Json::Object object;
    auto encoded_attached = encode_value(value.attached);
    if (!encoded_attached) return std::move(encoded_attached).error();
    object.emplace("attached", std::move(encoded_attached).value());
    auto encoded_client = encode_value(value.client);
    if (!encoded_client) return std::move(encoded_client).error();
    object.emplace("client", std::move(encoded_client).value());
    auto encoded_connected_seconds = encode_value(value.connected_seconds);
    if (!encoded_connected_seconds) return std::move(encoded_connected_seconds).error();
    object.emplace("connected_seconds", std::move(encoded_connected_seconds).value());
    if (value.kind) {
        auto encoded = encode_value(*value.kind);
        if (!encoded) return std::move(encoded).error();
        object.emplace("kind", std::move(encoded).value());
    } else {
        object.emplace("kind", Json(nullptr));
    }
    if (value.name) {
        auto encoded = encode_value(*value.name);
        if (!encoded) return std::move(encoded).error();
        object.emplace("name", std::move(encoded).value());
    } else {
        object.emplace("name", Json(nullptr));
    }
    auto encoded_self = encode_value(value.self);
    if (!encoded_self) return std::move(encoded_self).error();
    object.emplace("self", std::move(encoded_self).value());
    auto encoded_sizes = encode_value(value.sizes);
    if (!encoded_sizes) return std::move(encoded_sizes).error();
    object.emplace("sizes", std::move(encoded_sizes).value());
    auto encoded_transport = encode_value(value.transport);
    if (!encoded_transport) return std::move(encoded_transport).error();
    object.emplace("transport", std::move(encoded_transport).value());
    return Json(std::move(object));
}

Result<ClientInfo> Codec<ClientInfo>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ClientInfo result{};
    const Json* field_attached = value.find("attached");
    if (!field_attached) {
        return make_error(ErrorCode::decode, "missing required field 'attached'");
    }
    if (field_attached) {
        auto decoded = decode_value<std::vector<Id>>(*field_attached);
        if (!decoded) return std::move(decoded).error();
        result.attached = std::move(decoded).value();
    }
    const Json* field_client = value.find("client");
    if (!field_client) {
        return make_error(ErrorCode::decode, "missing required field 'client'");
    }
    if (field_client) {
        auto decoded = decode_value<std::uint64_t>(*field_client);
        if (!decoded) return std::move(decoded).error();
        result.client = std::move(decoded).value();
    }
    const Json* field_connected_seconds = value.find("connected_seconds");
    if (!field_connected_seconds) {
        return make_error(ErrorCode::decode, "missing required field 'connected_seconds'");
    }
    if (field_connected_seconds) {
        auto decoded = decode_value<std::uint64_t>(*field_connected_seconds);
        if (!decoded) return std::move(decoded).error();
        result.connected_seconds = std::move(decoded).value();
    }
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        if (field_kind->is_null()) {
            result.kind.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_kind);
            if (!decoded) return std::move(decoded).error();
            result.kind = std::move(decoded).value();
        }
    }
    const Json* field_name = value.find("name");
    if (!field_name) {
        return make_error(ErrorCode::decode, "missing required field 'name'");
    }
    if (field_name) {
        if (field_name->is_null()) {
            result.name.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_name);
            if (!decoded) return std::move(decoded).error();
            result.name = std::move(decoded).value();
        }
    }
    const Json* field_self = value.find("self");
    if (!field_self) {
        return make_error(ErrorCode::decode, "missing required field 'self'");
    }
    if (field_self) {
        auto decoded = decode_value<bool>(*field_self);
        if (!decoded) return std::move(decoded).error();
        result.self = std::move(decoded).value();
    }
    const Json* field_sizes = value.find("sizes");
    if (!field_sizes) {
        return make_error(ErrorCode::decode, "missing required field 'sizes'");
    }
    if (field_sizes) {
        auto decoded = decode_value<std::vector<ClientSize>>(*field_sizes);
        if (!decoded) return std::move(decoded).error();
        result.sizes = std::move(decoded).value();
    }
    const Json* field_transport = value.find("transport");
    if (!field_transport) {
        return make_error(ErrorCode::decode, "missing required field 'transport'");
    }
    if (field_transport) {
        auto decoded = decode_value<ClientTransport>(*field_transport);
        if (!decoded) return std::move(decoded).error();
        result.transport = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ClientSize>::encode(const ClientSize& value) {
    (void)value;
    Json::Object object;
    if (value.cols) {
        auto encoded = encode_value(*value.cols);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cols", std::move(encoded).value());
    } else {
        object.emplace("cols", Json(nullptr));
    }
    if (value.rows) {
        auto encoded = encode_value(*value.rows);
        if (!encoded) return std::move(encoded).error();
        object.emplace("rows", std::move(encoded).value());
    } else {
        object.emplace("rows", Json(nullptr));
    }
    auto encoded_size_participating = encode_value(value.size_participating);
    if (!encoded_size_participating) return std::move(encoded_size_participating).error();
    object.emplace("size_participating", std::move(encoded_size_participating).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<ClientSize> Codec<ClientSize>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ClientSize result{};
    const Json* field_cols = value.find("cols");
    if (!field_cols) {
        return make_error(ErrorCode::decode, "missing required field 'cols'");
    }
    if (field_cols) {
        if (field_cols->is_null()) {
            result.cols.reset();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_cols);
            if (!decoded) return std::move(decoded).error();
            result.cols = std::move(decoded).value();
        }
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        if (field_rows->is_null()) {
            result.rows.reset();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_rows);
            if (!decoded) return std::move(decoded).error();
            result.rows = std::move(decoded).value();
        }
    }
    const Json* field_size_participating = value.find("size_participating");
    if (!field_size_participating) {
        return make_error(ErrorCode::decode, "missing required field 'size_participating'");
    }
    if (field_size_participating) {
        auto decoded = decode_value<bool>(*field_size_participating);
        if (!decoded) return std::move(decoded).error();
        result.size_participating = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ClientTransport>::encode(const ClientTransport& value) {
    switch (value) {
        case ClientTransport::local: return Json(std::string("local"));
        case ClientTransport::unix_: return Json(std::string("unix"));
        case ClientTransport::ws: return Json(std::string("ws"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<ClientTransport> Codec<ClientTransport>::decode(const Json& value) {
    if (value == Json(std::string("local"))) return ClientTransport::local;
    if (value == Json(std::string("unix"))) return ClientTransport::unix_;
    if (value == Json(std::string("ws"))) return ClientTransport::ws;
    return make_error(ErrorCode::decode, "unknown ClientTransport value");
}

Result<Json> Codec<CloseTerminalResult>::encode(const CloseTerminalResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_already_closed = encode_value(value.already_closed);
    if (!encoded_already_closed) return std::move(encoded_already_closed).error();
    object.emplace("already_closed", std::move(encoded_already_closed).value());
    object.emplace("closed", Json(true));
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    auto encoded_registry_id = encode_value(value.registry_id);
    if (!encoded_registry_id) return std::move(encoded_registry_id).error();
    object.emplace("registry_id", std::move(encoded_registry_id).value());
    if (value.surface) {
        auto encoded = encode_value(*value.surface);
        if (!encoded) return std::move(encoded).error();
        object.emplace("surface", std::move(encoded).value());
    } else {
        object.emplace("surface", Json(nullptr));
    }
    auto encoded_terminal_id = encode_value(value.terminal_id);
    if (!encoded_terminal_id) return std::move(encoded_terminal_id).error();
    object.emplace("terminal_id", std::move(encoded_terminal_id).value());
    if (value.terminal_incarnation) {
        auto encoded = encode_value(*value.terminal_incarnation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal_incarnation", std::move(encoded).value());
    } else {
        object.emplace("terminal_incarnation", Json(nullptr));
    }
    auto encoded_terminal_revision = encode_value(value.terminal_revision);
    if (!encoded_terminal_revision) return std::move(encoded_terminal_revision).error();
    object.emplace("terminal_revision", std::move(encoded_terminal_revision).value());
    return Json(std::move(object));
}

Result<CloseTerminalResult> Codec<CloseTerminalResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    CloseTerminalResult result{};
    const Json* field_already_closed = value.find("already_closed");
    if (!field_already_closed) {
        return make_error(ErrorCode::decode, "missing required field 'already_closed'");
    }
    if (field_already_closed) {
        auto decoded = decode_value<bool>(*field_already_closed);
        if (!decoded) return std::move(decoded).error();
        result.already_closed = std::move(decoded).value();
    }
    const Json* field_closed = value.find("closed");
    if (!field_closed) {
        return make_error(ErrorCode::decode, "missing required field 'closed'");
    }
    if (field_closed) {
        if (*field_closed != Json(true)) {
            return make_error(ErrorCode::decode, "field 'closed' has the wrong literal value");
        }
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_registry_id = value.find("registry_id");
    if (!field_registry_id) {
        return make_error(ErrorCode::decode, "missing required field 'registry_id'");
    }
    if (field_registry_id) {
        auto decoded = decode_value<std::string>(*field_registry_id);
        if (!decoded) return std::move(decoded).error();
        result.registry_id = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        if (field_surface->is_null()) {
            result.surface.reset();
        } else {
            auto decoded = decode_value<Id>(*field_surface);
            if (!decoded) return std::move(decoded).error();
            result.surface = std::move(decoded).value();
        }
    }
    const Json* field_terminal_id = value.find("terminal_id");
    if (!field_terminal_id) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_id'");
    }
    if (field_terminal_id) {
        auto decoded = decode_value<std::string>(*field_terminal_id);
        if (!decoded) return std::move(decoded).error();
        result.terminal_id = std::move(decoded).value();
    }
    const Json* field_terminal_incarnation = value.find("terminal_incarnation");
    if (!field_terminal_incarnation) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_incarnation'");
    }
    if (field_terminal_incarnation) {
        if (field_terminal_incarnation->is_null()) {
            result.terminal_incarnation.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_terminal_incarnation);
            if (!decoded) return std::move(decoded).error();
            result.terminal_incarnation = std::move(decoded).value();
        }
    }
    const Json* field_terminal_revision = value.find("terminal_revision");
    if (!field_terminal_revision) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_revision'");
    }
    if (field_terminal_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_terminal_revision);
        if (!decoded) return std::move(decoded).error();
        result.terminal_revision = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ColorHex>::encode(const ColorHex& value) {
    return encode_value(value.value);
}

Result<ColorHex> Codec<ColorHex>::decode(const Json& value) {
    auto decoded = decode_value<std::string>(value);
    if (!decoded) return std::move(decoded).error();
    return ColorHex{std::move(decoded).value()};
}

Result<Json> Codec<CopyResult>::encode(const CopyResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_mode = encode_value(value.mode);
    if (!encoded_mode) return std::move(encoded_mode).error();
    object.emplace("mode", std::move(encoded_mode).value());
    auto encoded_text = encode_value(value.text);
    if (!encoded_text) return std::move(encoded_text).error();
    object.emplace("text", std::move(encoded_text).value());
    return Json(std::move(object));
}

Result<CopyResult> Codec<CopyResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    CopyResult result{};
    const Json* field_mode = value.find("mode");
    if (!field_mode) {
        return make_error(ErrorCode::decode, "missing required field 'mode'");
    }
    if (field_mode) {
        auto decoded = decode_value<CopyResultMode>(*field_mode);
        if (!decoded) return std::move(decoded).error();
        result.mode = std::move(decoded).value();
    }
    const Json* field_text = value.find("text");
    if (!field_text) {
        return make_error(ErrorCode::decode, "missing required field 'text'");
    }
    if (field_text) {
        auto decoded = decode_value<std::string>(*field_text);
        if (!decoded) return std::move(decoded).error();
        result.text = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<CursorStyle>::encode(const CursorStyle& value) {
    switch (value) {
        case CursorStyle::block: return Json(std::string("block"));
        case CursorStyle::underline: return Json(std::string("underline"));
        case CursorStyle::bar: return Json(std::string("bar"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<CursorStyle> Codec<CursorStyle>::decode(const Json& value) {
    if (value == Json(std::string("block"))) return CursorStyle::block;
    if (value == Json(std::string("underline"))) return CursorStyle::underline;
    if (value == Json(std::string("bar"))) return CursorStyle::bar;
    return make_error(ErrorCode::decode, "unknown CursorStyle value");
}

Result<Json> Codec<DeadPane>::encode(const DeadPane& value) {
    (void)value;
    Json::Object object;
    object.emplace("dead", Json(true));
    auto encoded_id = encode_value(value.id);
    if (!encoded_id) return std::move(encoded_id).error();
    object.emplace("id", std::move(encoded_id).value());
    return Json(std::move(object));
}

Result<DeadPane> Codec<DeadPane>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    DeadPane result{};
    const Json* field_dead = value.find("dead");
    if (!field_dead) {
        return make_error(ErrorCode::decode, "missing required field 'dead'");
    }
    if (field_dead) {
        if (*field_dead != Json(true)) {
            return make_error(ErrorCode::decode, "field 'dead' has the wrong literal value");
        }
    }
    const Json* field_id = value.find("id");
    if (!field_id) {
        return make_error(ErrorCode::decode, "missing required field 'id'");
    }
    if (field_id) {
        auto decoded = decode_value<Id>(*field_id);
        if (!decoded) return std::move(decoded).error();
        result.id = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<DeclarativeLayout>::encode(const DeclarativeLayout& value) {
    return encode_value(value.value);
}

Result<DeclarativeLayout> Codec<DeclarativeLayout>::decode(const Json& value) {
    auto tag = require_string(value, "type");
    if (!tag) return std::move(tag).error();
    if (tag.value() == "leaf") {
        auto decoded = decode_value<DeclarativeLayoutLeaf>(value);
        if (!decoded) return std::move(decoded).error();
        return DeclarativeLayout{DeclarativeLayout::Variant(std::move(decoded).value())};
    }
    if (tag.value() == "split") {
        auto decoded = decode_value<DeclarativeLayoutSplit>(value);
        if (!decoded) return std::move(decoded).error();
        return DeclarativeLayout{DeclarativeLayout::Variant(std::move(decoded).value())};
    }
    if (tag.value() == "stack") {
        auto decoded = decode_value<DeclarativeLayoutStack>(value);
        if (!decoded) return std::move(decoded).error();
        return DeclarativeLayout{DeclarativeLayout::Variant(std::move(decoded).value())};
    }
    return make_error(ErrorCode::decode, "unknown DeclarativeLayout tag");
}

Result<Json> Codec<EmptyResult>::encode(const EmptyResult& value) {
    (void)value;
    Json::Object object;
    return Json(std::move(object));
}

Result<EmptyResult> Codec<EmptyResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    EmptyResult result{};
    return result;
}

Result<Json> Codec<ExportLayoutResult>::encode(const ExportLayoutResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_layout = encode_value(value.layout);
    if (!encoded_layout) return std::move(encoded_layout).error();
    object.emplace("layout", std::move(encoded_layout).value());
    auto encoded_panes = encode_value(value.panes);
    if (!encoded_panes) return std::move(encoded_panes).error();
    object.emplace("panes", std::move(encoded_panes).value());
    return Json(std::move(object));
}

Result<ExportLayoutResult> Codec<ExportLayoutResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ExportLayoutResult result{};
    const Json* field_layout = value.find("layout");
    if (!field_layout) {
        return make_error(ErrorCode::decode, "missing required field 'layout'");
    }
    if (field_layout) {
        auto decoded = decode_value<Layout>(*field_layout);
        if (!decoded) return std::move(decoded).error();
        result.layout = std::move(decoded).value();
    }
    const Json* field_panes = value.find("panes");
    if (!field_panes) {
        return make_error(ErrorCode::decode, "missing required field 'panes'");
    }
    if (field_panes) {
        auto decoded = decode_value<std::vector<ExportedPane>>(*field_panes);
        if (!decoded) return std::move(decoded).error();
        result.panes = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ExportedPane>::encode(const ExportedPane& value) {
    (void)value;
    Json::Object object;
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    auto encoded_surfaces = encode_value(value.surfaces);
    if (!encoded_surfaces) return std::move(encoded_surfaces).error();
    object.emplace("surfaces", std::move(encoded_surfaces).value());
    return Json(std::move(object));
}

Result<ExportedPane> Codec<ExportedPane>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ExportedPane result{};
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_surfaces = value.find("surfaces");
    if (!field_surfaces) {
        return make_error(ErrorCode::decode, "missing required field 'surfaces'");
    }
    if (field_surfaces) {
        auto decoded = decode_value<std::vector<Id>>(*field_surfaces);
        if (!decoded) return std::move(decoded).error();
        result.surfaces = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<FocusDirectionResult>::encode(const FocusDirectionResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    return Json(std::move(object));
}

Result<FocusDirectionResult> Codec<FocusDirectionResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    FocusDirectionResult result{};
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<FrontendFocusTarget>::encode(const FrontendFocusTarget& value) {
    switch (value) {
        case FrontendFocusTarget::pane: return Json(std::string("pane"));
        case FrontendFocusTarget::machine_rail: return Json(std::string("machine_rail"));
        case FrontendFocusTarget::workspace_rail: return Json(std::string("workspace_rail"));
        case FrontendFocusTarget::tabs_rail: return Json(std::string("tabs_rail"));
        case FrontendFocusTarget::projection_rail: return Json(std::string("projection_rail"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<FrontendFocusTarget> Codec<FrontendFocusTarget>::decode(const Json& value) {
    if (value == Json(std::string("pane"))) return FrontendFocusTarget::pane;
    if (value == Json(std::string("machine_rail"))) return FrontendFocusTarget::machine_rail;
    if (value == Json(std::string("workspace_rail"))) return FrontendFocusTarget::workspace_rail;
    if (value == Json(std::string("tabs_rail"))) return FrontendFocusTarget::tabs_rail;
    if (value == Json(std::string("projection_rail"))) return FrontendFocusTarget::projection_rail;
    return make_error(ErrorCode::decode, "unknown FrontendFocusTarget value");
}

Result<Json> Codec<FrontendJournalEvent>::encode(const FrontendJournalEvent& value) {
    return encode_value(value.value);
}

Result<FrontendJournalEvent> Codec<FrontendJournalEvent>::decode(const Json& value) {
    auto tag = require_string(value, "kind");
    if (!tag) return std::move(tag).error();
    if (tag.value() == "focus") {
        auto decoded = decode_value<FrontendJournalEventFocus>(value);
        if (!decoded) return std::move(decoded).error();
        return FrontendJournalEvent{FrontendJournalEvent::Variant(std::move(decoded).value())};
    }
    if (tag.value() == "resize") {
        auto decoded = decode_value<FrontendJournalEventResize>(value);
        if (!decoded) return std::move(decoded).error();
        return FrontendJournalEvent{FrontendJournalEvent::Variant(std::move(decoded).value())};
    }
    if (tag.value() == "viewport") {
        auto decoded = decode_value<FrontendJournalEventViewport>(value);
        if (!decoded) return std::move(decoded).error();
        return FrontendJournalEvent{FrontendJournalEvent::Variant(std::move(decoded).value())};
    }
    return make_error(ErrorCode::decode, "unknown FrontendJournalEvent tag");
}

Result<Json> Codec<FrontendProjection>::encode(const FrontendProjection& value) {
    (void)value;
    Json::Object object;
    auto encoded_frontend = encode_value(value.frontend);
    if (!encoded_frontend) return std::move(encoded_frontend).error();
    object.emplace("frontend", std::move(encoded_frontend).value());
    if (value.projection) {
        auto encoded = encode_value(*value.projection);
        if (!encoded) return std::move(encoded).error();
        object.emplace("projection", std::move(encoded).value());
    } else {
        object.emplace("projection", Json(nullptr));
    }
    auto encoded_projection_revision = encode_value(value.projection_revision);
    if (!encoded_projection_revision) return std::move(encoded_projection_revision).error();
    object.emplace("projection_revision", std::move(encoded_projection_revision).value());
    if (value.replayed) {
        auto encoded = encode_value(*value.replayed);
        if (!encoded) return std::move(encoded).error();
        object.emplace("replayed", std::move(encoded).value());
    }
    auto encoded_schema_version = encode_value(value.schema_version);
    if (!encoded_schema_version) return std::move(encoded_schema_version).error();
    object.emplace("schema_version", std::move(encoded_schema_version).value());
    auto encoded_scope = encode_value(value.scope);
    if (!encoded_scope) return std::move(encoded_scope).error();
    object.emplace("scope", std::move(encoded_scope).value());
    auto encoded_subject_key = encode_value(value.subject_key);
    if (!encoded_subject_key) return std::move(encoded_subject_key).error();
    object.emplace("subject_key", std::move(encoded_subject_key).value());
    return Json(std::move(object));
}

Result<FrontendProjection> Codec<FrontendProjection>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    FrontendProjection result{};
    const Json* field_frontend = value.find("frontend");
    if (!field_frontend) {
        return make_error(ErrorCode::decode, "missing required field 'frontend'");
    }
    if (field_frontend) {
        auto decoded = decode_value<std::string>(*field_frontend);
        if (!decoded) return std::move(decoded).error();
        result.frontend = std::move(decoded).value();
    }
    const Json* field_projection = value.find("projection");
    if (!field_projection) {
        return make_error(ErrorCode::decode, "missing required field 'projection'");
    }
    if (field_projection) {
        if (field_projection->is_null()) {
            result.projection.reset();
        } else {
            auto decoded = decode_value<JsonValue>(*field_projection);
            if (!decoded) return std::move(decoded).error();
            result.projection = std::move(decoded).value();
        }
    }
    const Json* field_projection_revision = value.find("projection_revision");
    if (!field_projection_revision) {
        return make_error(ErrorCode::decode, "missing required field 'projection_revision'");
    }
    if (field_projection_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_projection_revision);
        if (!decoded) return std::move(decoded).error();
        result.projection_revision = std::move(decoded).value();
    }
    const Json* field_replayed = value.find("replayed");
    if (field_replayed) {
        auto decoded = decode_value<bool>(*field_replayed);
        if (!decoded) return std::move(decoded).error();
        result.replayed = std::move(decoded).value();
    }
    const Json* field_schema_version = value.find("schema_version");
    if (!field_schema_version) {
        return make_error(ErrorCode::decode, "missing required field 'schema_version'");
    }
    if (field_schema_version) {
        auto decoded = decode_value<std::uint32_t>(*field_schema_version);
        if (!decoded) return std::move(decoded).error();
        result.schema_version = std::move(decoded).value();
    }
    const Json* field_scope = value.find("scope");
    if (!field_scope) {
        return make_error(ErrorCode::decode, "missing required field 'scope'");
    }
    if (field_scope) {
        auto decoded = decode_value<std::string>(*field_scope);
        if (!decoded) return std::move(decoded).error();
        result.scope = std::move(decoded).value();
    }
    const Json* field_subject_key = value.find("subject_key");
    if (!field_subject_key) {
        return make_error(ErrorCode::decode, "missing required field 'subject_key'");
    }
    if (field_subject_key) {
        auto decoded = decode_value<std::string>(*field_subject_key);
        if (!decoded) return std::move(decoded).error();
        result.subject_key = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<GetCellPixelsResult>::encode(const GetCellPixelsResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_height_px = encode_value(value.height_px);
    if (!encoded_height_px) return std::move(encoded_height_px).error();
    object.emplace("height_px", std::move(encoded_height_px).value());
    auto encoded_surfaces = encode_value(value.surfaces);
    if (!encoded_surfaces) return std::move(encoded_surfaces).error();
    object.emplace("surfaces", std::move(encoded_surfaces).value());
    auto encoded_width_px = encode_value(value.width_px);
    if (!encoded_width_px) return std::move(encoded_width_px).error();
    object.emplace("width_px", std::move(encoded_width_px).value());
    return Json(std::move(object));
}

Result<GetCellPixelsResult> Codec<GetCellPixelsResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    GetCellPixelsResult result{};
    const Json* field_height_px = value.find("height_px");
    if (!field_height_px) {
        return make_error(ErrorCode::decode, "missing required field 'height_px'");
    }
    if (field_height_px) {
        auto decoded = decode_value<std::uint16_t>(*field_height_px);
        if (!decoded) return std::move(decoded).error();
        result.height_px = std::move(decoded).value();
    }
    const Json* field_surfaces = value.find("surfaces");
    if (!field_surfaces) {
        return make_error(ErrorCode::decode, "missing required field 'surfaces'");
    }
    if (field_surfaces) {
        auto decoded = decode_value<std::vector<CellPixelSurface>>(*field_surfaces);
        if (!decoded) return std::move(decoded).error();
        result.surfaces = std::move(decoded).value();
    }
    const Json* field_width_px = value.find("width_px");
    if (!field_width_px) {
        return make_error(ErrorCode::decode, "missing required field 'width_px'");
    }
    if (field_width_px) {
        auto decoded = decode_value<std::uint16_t>(*field_width_px);
        if (!decoded) return std::move(decoded).error();
        result.width_px = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<Id>::encode(const Id& value) {
    return encode_value(value.value);
}

Result<Id> Codec<Id>::decode(const Json& value) {
    auto decoded = decode_value<std::uint64_t>(value);
    if (!decoded) return std::move(decoded).error();
    return Id{std::move(decoded).value()};
}

Result<Json> Codec<IdMapping>::encode(const IdMapping& value) {
    (void)value;
    Json::Object object;
    auto encoded_id = encode_value(value.id);
    if (!encoded_id) return std::move(encoded_id).error();
    object.emplace("id", std::move(encoded_id).value());
    auto encoded_kind = encode_value(value.kind);
    if (!encoded_kind) return std::move(encoded_kind).error();
    object.emplace("kind", std::move(encoded_kind).value());
    auto encoded_short_id = encode_value(value.short_id);
    if (!encoded_short_id) return std::move(encoded_short_id).error();
    object.emplace("short_id", std::move(encoded_short_id).value());
    return Json(std::move(object));
}

Result<IdMapping> Codec<IdMapping>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    IdMapping result{};
    const Json* field_id = value.find("id");
    if (!field_id) {
        return make_error(ErrorCode::decode, "missing required field 'id'");
    }
    if (field_id) {
        auto decoded = decode_value<Id>(*field_id);
        if (!decoded) return std::move(decoded).error();
        result.id = std::move(decoded).value();
    }
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        auto decoded = decode_value<IdMappingKind>(*field_kind);
        if (!decoded) return std::move(decoded).error();
        result.kind = std::move(decoded).value();
    }
    const Json* field_short_id = value.find("short_id");
    if (!field_short_id) {
        return make_error(ErrorCode::decode, "missing required field 'short_id'");
    }
    if (field_short_id) {
        auto decoded = decode_value<std::string>(*field_short_id);
        if (!decoded) return std::move(decoded).error();
        result.short_id = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<IdentifyResult>::encode(const IdentifyResult& value) {
    (void)value;
    Json::Object object;
    object.emplace("app", Json(std::string("cmux-tui")));
    if (!value.build_commit.is_absent()) {
        auto encoded = encode_value(value.build_commit);
        if (!encoded) return std::move(encoded).error();
        object.emplace("build_commit", std::move(encoded).value());
    }
    if (value.capabilities) {
        auto encoded = encode_value(*value.capabilities);
        if (!encoded) return std::move(encoded).error();
        object.emplace("capabilities", std::move(encoded).value());
    }
    object.emplace("daemon_handoff", Json(static_cast<std::uint64_t>(1ULL)));
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    if (!value.ghostty_commit.is_absent()) {
        auto encoded = encode_value(value.ghostty_commit);
        if (!encoded) return std::move(encoded).error();
        object.emplace("ghostty_commit", std::move(encoded).value());
    }
    if (value.lifecycle_ready) {
        auto encoded = encode_value(*value.lifecycle_ready);
        if (!encoded) return std::move(encoded).error();
        object.emplace("lifecycle_ready", std::move(encoded).value());
    }
    auto encoded_pid = encode_value(value.pid);
    if (!encoded_pid) return std::move(encoded_pid).error();
    object.emplace("pid", std::move(encoded_pid).value());
    auto encoded_protocol = encode_value(value.protocol);
    if (!encoded_protocol) return std::move(encoded_protocol).error();
    object.emplace("protocol", std::move(encoded_protocol).value());
    auto encoded_registry_id = encode_value(value.registry_id);
    if (!encoded_registry_id) return std::move(encoded_registry_id).error();
    object.emplace("registry_id", std::move(encoded_registry_id).value());
    auto encoded_session = encode_value(value.session);
    if (!encoded_session) return std::move(encoded_session).error();
    object.emplace("session", std::move(encoded_session).value());
    auto encoded_terminal_revision = encode_value(value.terminal_revision);
    if (!encoded_terminal_revision) return std::move(encoded_terminal_revision).error();
    object.emplace("terminal_revision", std::move(encoded_terminal_revision).value());
    auto encoded_version = encode_value(value.version);
    if (!encoded_version) return std::move(encoded_version).error();
    object.emplace("version", std::move(encoded_version).value());
    auto encoded_workspace_revision = encode_value(value.workspace_revision);
    if (!encoded_workspace_revision) return std::move(encoded_workspace_revision).error();
    object.emplace("workspace_revision", std::move(encoded_workspace_revision).value());
    return Json(std::move(object));
}

Result<IdentifyResult> Codec<IdentifyResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    IdentifyResult result{};
    const Json* field_app = value.find("app");
    if (!field_app) {
        return make_error(ErrorCode::decode, "missing required field 'app'");
    }
    if (field_app) {
        if (*field_app != Json(std::string("cmux-tui"))) {
            return make_error(ErrorCode::decode, "field 'app' has the wrong literal value");
        }
    }
    const Json* field_build_commit = value.find("build_commit");
    if (field_build_commit) {
        if (field_build_commit->is_null()) {
            result.build_commit = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_build_commit);
            if (!decoded) return std::move(decoded).error();
            result.build_commit = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_capabilities = value.find("capabilities");
    if (field_capabilities) {
        auto decoded = decode_value<std::vector<std::string>>(*field_capabilities);
        if (!decoded) return std::move(decoded).error();
        result.capabilities = std::move(decoded).value();
    }
    const Json* field_daemon_handoff = value.find("daemon_handoff");
    if (!field_daemon_handoff) {
        return make_error(ErrorCode::decode, "missing required field 'daemon_handoff'");
    }
    if (field_daemon_handoff) {
        if (*field_daemon_handoff != Json(static_cast<std::uint64_t>(1ULL))) {
            return make_error(ErrorCode::decode, "field 'daemon_handoff' has the wrong literal value");
        }
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_ghostty_commit = value.find("ghostty_commit");
    if (field_ghostty_commit) {
        if (field_ghostty_commit->is_null()) {
            result.ghostty_commit = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_ghostty_commit);
            if (!decoded) return std::move(decoded).error();
            result.ghostty_commit = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_lifecycle_ready = value.find("lifecycle_ready");
    if (field_lifecycle_ready) {
        auto decoded = decode_value<bool>(*field_lifecycle_ready);
        if (!decoded) return std::move(decoded).error();
        result.lifecycle_ready = std::move(decoded).value();
    }
    const Json* field_pid = value.find("pid");
    if (!field_pid) {
        return make_error(ErrorCode::decode, "missing required field 'pid'");
    }
    if (field_pid) {
        auto decoded = decode_value<std::uint32_t>(*field_pid);
        if (!decoded) return std::move(decoded).error();
        result.pid = std::move(decoded).value();
    }
    const Json* field_protocol = value.find("protocol");
    if (!field_protocol) {
        return make_error(ErrorCode::decode, "missing required field 'protocol'");
    }
    if (field_protocol) {
        auto decoded = decode_value<std::uint32_t>(*field_protocol);
        if (!decoded) return std::move(decoded).error();
        result.protocol = std::move(decoded).value();
    }
    const Json* field_registry_id = value.find("registry_id");
    if (!field_registry_id) {
        return make_error(ErrorCode::decode, "missing required field 'registry_id'");
    }
    if (field_registry_id) {
        auto decoded = decode_value<std::string>(*field_registry_id);
        if (!decoded) return std::move(decoded).error();
        result.registry_id = std::move(decoded).value();
    }
    const Json* field_session = value.find("session");
    if (!field_session) {
        return make_error(ErrorCode::decode, "missing required field 'session'");
    }
    if (field_session) {
        auto decoded = decode_value<std::string>(*field_session);
        if (!decoded) return std::move(decoded).error();
        result.session = std::move(decoded).value();
    }
    const Json* field_terminal_revision = value.find("terminal_revision");
    if (!field_terminal_revision) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_revision'");
    }
    if (field_terminal_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_terminal_revision);
        if (!decoded) return std::move(decoded).error();
        result.terminal_revision = std::move(decoded).value();
    }
    const Json* field_version = value.find("version");
    if (!field_version) {
        return make_error(ErrorCode::decode, "missing required field 'version'");
    }
    if (field_version) {
        auto decoded = decode_value<std::string>(*field_version);
        if (!decoded) return std::move(decoded).error();
        result.version = std::move(decoded).value();
    }
    const Json* field_workspace_revision = value.find("workspace_revision");
    if (!field_workspace_revision) {
        return make_error(ErrorCode::decode, "missing required field 'workspace_revision'");
    }
    if (field_workspace_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_workspace_revision);
        if (!decoded) return std::move(decoded).error();
        result.workspace_revision = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<IdsResult>::encode(const IdsResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_ids = encode_value(value.ids);
    if (!encoded_ids) return std::move(encoded_ids).error();
    object.emplace("ids", std::move(encoded_ids).value());
    return Json(std::move(object));
}

Result<IdsResult> Codec<IdsResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    IdsResult result{};
    const Json* field_ids = value.find("ids");
    if (!field_ids) {
        return make_error(ErrorCode::decode, "missing required field 'ids'");
    }
    if (field_ids) {
        auto decoded = decode_value<std::vector<IdMapping>>(*field_ids);
        if (!decoded) return std::move(decoded).error();
        result.ids = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<JsonValue>::encode(const JsonValue& value) {
    return encode_value(value.value);
}

Result<JsonValue> Codec<JsonValue>::decode(const Json& value) {
    auto decoded = decode_value<Json>(value);
    if (!decoded) return std::move(decoded).error();
    return JsonValue{std::move(decoded).value()};
}

Result<Json> Codec<KittyGraphicsState>::encode(const KittyGraphicsState& value) {
    (void)value;
    Json::Object object;
    auto encoded_alternate_next_image_id = encode_value(value.alternate_next_image_id);
    if (!encoded_alternate_next_image_id) return std::move(encoded_alternate_next_image_id).error();
    object.emplace("alternate_next_image_id", std::move(encoded_alternate_next_image_id).value());
    auto encoded_alternate_replay_next_image_id = encode_value(value.alternate_replay_next_image_id);
    if (!encoded_alternate_replay_next_image_id) return std::move(encoded_alternate_replay_next_image_id).error();
    object.emplace("alternate_replay_next_image_id", std::move(encoded_alternate_replay_next_image_id).value());
    auto encoded_image_bytes = encode_value(value.image_bytes);
    if (!encoded_image_bytes) return std::move(encoded_image_bytes).error();
    object.emplace("image_bytes", std::move(encoded_image_bytes).value());
    auto encoded_images = encode_value(value.images);
    if (!encoded_images) return std::move(encoded_images).error();
    object.emplace("images", std::move(encoded_images).value());
    auto encoded_inflight_bytes = encode_value(value.inflight_bytes);
    if (!encoded_inflight_bytes) return std::move(encoded_inflight_bytes).error();
    object.emplace("inflight_bytes", std::move(encoded_inflight_bytes).value());
    auto encoded_placements = encode_value(value.placements);
    if (!encoded_placements) return std::move(encoded_placements).error();
    object.emplace("placements", std::move(encoded_placements).value());
    auto encoded_primary_next_image_id = encode_value(value.primary_next_image_id);
    if (!encoded_primary_next_image_id) return std::move(encoded_primary_next_image_id).error();
    object.emplace("primary_next_image_id", std::move(encoded_primary_next_image_id).value());
    auto encoded_primary_replay_next_image_id = encode_value(value.primary_replay_next_image_id);
    if (!encoded_primary_replay_next_image_id) return std::move(encoded_primary_replay_next_image_id).error();
    object.emplace("primary_replay_next_image_id", std::move(encoded_primary_replay_next_image_id).value());
    auto encoded_replay_cursor_offset = encode_value(value.replay_cursor_offset);
    if (!encoded_replay_cursor_offset) return std::move(encoded_replay_cursor_offset).error();
    object.emplace("replay_cursor_offset", std::move(encoded_replay_cursor_offset).value());
    return Json(std::move(object));
}

Result<KittyGraphicsState> Codec<KittyGraphicsState>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    KittyGraphicsState result{};
    const Json* field_alternate_next_image_id = value.find("alternate_next_image_id");
    if (!field_alternate_next_image_id) {
        return make_error(ErrorCode::decode, "missing required field 'alternate_next_image_id'");
    }
    if (field_alternate_next_image_id) {
        auto decoded = decode_value<std::uint32_t>(*field_alternate_next_image_id);
        if (!decoded) return std::move(decoded).error();
        result.alternate_next_image_id = std::move(decoded).value();
    }
    const Json* field_alternate_replay_next_image_id = value.find("alternate_replay_next_image_id");
    if (!field_alternate_replay_next_image_id) {
        return make_error(ErrorCode::decode, "missing required field 'alternate_replay_next_image_id'");
    }
    if (field_alternate_replay_next_image_id) {
        auto decoded = decode_value<std::uint32_t>(*field_alternate_replay_next_image_id);
        if (!decoded) return std::move(decoded).error();
        result.alternate_replay_next_image_id = std::move(decoded).value();
    }
    const Json* field_image_bytes = value.find("image_bytes");
    if (!field_image_bytes) {
        return make_error(ErrorCode::decode, "missing required field 'image_bytes'");
    }
    if (field_image_bytes) {
        auto decoded = decode_value<std::uint64_t>(*field_image_bytes);
        if (!decoded) return std::move(decoded).error();
        result.image_bytes = std::move(decoded).value();
    }
    const Json* field_images = value.find("images");
    if (!field_images) {
        return make_error(ErrorCode::decode, "missing required field 'images'");
    }
    if (field_images) {
        auto decoded = decode_value<std::uint64_t>(*field_images);
        if (!decoded) return std::move(decoded).error();
        result.images = std::move(decoded).value();
    }
    const Json* field_inflight_bytes = value.find("inflight_bytes");
    if (!field_inflight_bytes) {
        return make_error(ErrorCode::decode, "missing required field 'inflight_bytes'");
    }
    if (field_inflight_bytes) {
        auto decoded = decode_value<std::uint64_t>(*field_inflight_bytes);
        if (!decoded) return std::move(decoded).error();
        result.inflight_bytes = std::move(decoded).value();
    }
    const Json* field_placements = value.find("placements");
    if (!field_placements) {
        return make_error(ErrorCode::decode, "missing required field 'placements'");
    }
    if (field_placements) {
        auto decoded = decode_value<std::uint64_t>(*field_placements);
        if (!decoded) return std::move(decoded).error();
        result.placements = std::move(decoded).value();
    }
    const Json* field_primary_next_image_id = value.find("primary_next_image_id");
    if (!field_primary_next_image_id) {
        return make_error(ErrorCode::decode, "missing required field 'primary_next_image_id'");
    }
    if (field_primary_next_image_id) {
        auto decoded = decode_value<std::uint32_t>(*field_primary_next_image_id);
        if (!decoded) return std::move(decoded).error();
        result.primary_next_image_id = std::move(decoded).value();
    }
    const Json* field_primary_replay_next_image_id = value.find("primary_replay_next_image_id");
    if (!field_primary_replay_next_image_id) {
        return make_error(ErrorCode::decode, "missing required field 'primary_replay_next_image_id'");
    }
    if (field_primary_replay_next_image_id) {
        auto decoded = decode_value<std::uint32_t>(*field_primary_replay_next_image_id);
        if (!decoded) return std::move(decoded).error();
        result.primary_replay_next_image_id = std::move(decoded).value();
    }
    const Json* field_replay_cursor_offset = value.find("replay_cursor_offset");
    if (!field_replay_cursor_offset) {
        return make_error(ErrorCode::decode, "missing required field 'replay_cursor_offset'");
    }
    if (field_replay_cursor_offset) {
        auto decoded = decode_value<std::uint32_t>(*field_replay_cursor_offset);
        if (!decoded) return std::move(decoded).error();
        result.replay_cursor_offset = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<KittyImageAlias>::encode(const KittyImageAlias& value) {
    (void)value;
    Json::Object object;
    auto encoded_image_id = encode_value(value.image_id);
    if (!encoded_image_id) return std::move(encoded_image_id).error();
    object.emplace("image_id", std::move(encoded_image_id).value());
    auto encoded_image_number = encode_value(value.image_number);
    if (!encoded_image_number) return std::move(encoded_image_number).error();
    object.emplace("image_number", std::move(encoded_image_number).value());
    return Json(std::move(object));
}

Result<KittyImageAlias> Codec<KittyImageAlias>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    KittyImageAlias result{};
    const Json* field_image_id = value.find("image_id");
    if (!field_image_id) {
        return make_error(ErrorCode::decode, "missing required field 'image_id'");
    }
    if (field_image_id) {
        auto decoded = decode_value<std::uint32_t>(*field_image_id);
        if (!decoded) return std::move(decoded).error();
        result.image_id = std::move(decoded).value();
    }
    const Json* field_image_number = value.find("image_number");
    if (!field_image_number) {
        return make_error(ErrorCode::decode, "missing required field 'image_number'");
    }
    if (field_image_number) {
        auto decoded = decode_value<std::uint32_t>(*field_image_number);
        if (!decoded) return std::move(decoded).error();
        result.image_number = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<Layout>::encode(const Layout& value) {
    return encode_value(value.value);
}

Result<Layout> Codec<Layout>::decode(const Json& value) {
    auto tag = require_string(value, "type");
    if (!tag) return std::move(tag).error();
    if (tag.value() == "leaf") {
        auto decoded = decode_value<LayoutLeaf>(value);
        if (!decoded) return std::move(decoded).error();
        return Layout{Layout::Variant(std::move(decoded).value())};
    }
    if (tag.value() == "split") {
        auto decoded = decode_value<LayoutSplit>(value);
        if (!decoded) return std::move(decoded).error();
        return Layout{Layout::Variant(std::move(decoded).value())};
    }
    if (tag.value() == "stack") {
        auto decoded = decode_value<LayoutStack>(value);
        if (!decoded) return std::move(decoded).error();
        return Layout{Layout::Variant(std::move(decoded).value())};
    }
    return make_error(ErrorCode::decode, "unknown Layout tag");
}

Result<Json> Codec<LayoutUndoConfirmationRequired>::encode(const LayoutUndoConfirmationRequired& value) {
    (void)value;
    Json::Object object;
    auto encoded_closes_panes = encode_value(value.closes_panes);
    if (!encoded_closes_panes) return std::move(encoded_closes_panes).error();
    object.emplace("closes_panes", std::move(encoded_closes_panes).value());
    object.emplace("confirmation_required", Json(true));
    auto encoded_revision = encode_value(value.revision);
    if (!encoded_revision) return std::move(encoded_revision).error();
    object.emplace("revision", std::move(encoded_revision).value());
    auto encoded_screen = encode_value(value.screen);
    if (!encoded_screen) return std::move(encoded_screen).error();
    object.emplace("screen", std::move(encoded_screen).value());
    object.emplace("undone", Json(false));
    return Json(std::move(object));
}

Result<LayoutUndoConfirmationRequired> Codec<LayoutUndoConfirmationRequired>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    LayoutUndoConfirmationRequired result{};
    const Json* field_closes_panes = value.find("closes_panes");
    if (!field_closes_panes) {
        return make_error(ErrorCode::decode, "missing required field 'closes_panes'");
    }
    if (field_closes_panes) {
        auto decoded = decode_value<std::vector<Id>>(*field_closes_panes);
        if (!decoded) return std::move(decoded).error();
        result.closes_panes = std::move(decoded).value();
    }
    const Json* field_confirmation_required = value.find("confirmation_required");
    if (!field_confirmation_required) {
        return make_error(ErrorCode::decode, "missing required field 'confirmation_required'");
    }
    if (field_confirmation_required) {
        if (*field_confirmation_required != Json(true)) {
            return make_error(ErrorCode::decode, "field 'confirmation_required' has the wrong literal value");
        }
    }
    const Json* field_revision = value.find("revision");
    if (!field_revision) {
        return make_error(ErrorCode::decode, "missing required field 'revision'");
    }
    if (field_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_revision);
        if (!decoded) return std::move(decoded).error();
        result.revision = std::move(decoded).value();
    }
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        auto decoded = decode_value<Id>(*field_screen);
        if (!decoded) return std::move(decoded).error();
        result.screen = std::move(decoded).value();
    }
    const Json* field_undone = value.find("undone");
    if (!field_undone) {
        return make_error(ErrorCode::decode, "missing required field 'undone'");
    }
    if (field_undone) {
        if (*field_undone != Json(false)) {
            return make_error(ErrorCode::decode, "field 'undone' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<LayoutUndoResult>::encode(const LayoutUndoResult& value) {
    return encode_value(value.value);
}

Result<LayoutUndoResult> Codec<LayoutUndoResult>::decode(const Json& value) {
    if (auto decoded = decode_value<LayoutUndoUndone>(value); decoded) {
        return LayoutUndoResult{LayoutUndoResult::Variant(std::move(decoded).value())};
    }
    if (auto decoded = decode_value<LayoutUndoConfirmationRequired>(value); decoded) {
        return LayoutUndoResult{LayoutUndoResult::Variant(std::move(decoded).value())};
    }
    return make_error(ErrorCode::decode, "value did not match any LayoutUndoResult variant");
}

Result<Json> Codec<LayoutUndoUndone>::encode(const LayoutUndoUndone& value) {
    (void)value;
    Json::Object object;
    if (value.confirmation_required) {
        auto encoded = encode_value(*value.confirmation_required);
        if (!encoded) return std::move(encoded).error();
        if (encoded.value() != Json(false)) {
            return make_error(ErrorCode::invalid_argument, "field 'confirmation_required' has the wrong literal value");
        }
        object.emplace("confirmation_required", std::move(encoded).value());
    }
    auto encoded_revision = encode_value(value.revision);
    if (!encoded_revision) return std::move(encoded_revision).error();
    object.emplace("revision", std::move(encoded_revision).value());
    auto encoded_screen = encode_value(value.screen);
    if (!encoded_screen) return std::move(encoded_screen).error();
    object.emplace("screen", std::move(encoded_screen).value());
    object.emplace("undone", Json(true));
    return Json(std::move(object));
}

Result<LayoutUndoUndone> Codec<LayoutUndoUndone>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    LayoutUndoUndone result{};
    const Json* field_confirmation_required = value.find("confirmation_required");
    if (field_confirmation_required) {
        if (*field_confirmation_required != Json(false)) {
            return make_error(ErrorCode::decode, "field 'confirmation_required' has the wrong literal value");
        }
        result.confirmation_required = false;
    }
    const Json* field_revision = value.find("revision");
    if (!field_revision) {
        return make_error(ErrorCode::decode, "missing required field 'revision'");
    }
    if (field_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_revision);
        if (!decoded) return std::move(decoded).error();
        result.revision = std::move(decoded).value();
    }
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        auto decoded = decode_value<Id>(*field_screen);
        if (!decoded) return std::move(decoded).error();
        result.screen = std::move(decoded).value();
    }
    const Json* field_undone = value.find("undone");
    if (!field_undone) {
        return make_error(ErrorCode::decode, "missing required field 'undone'");
    }
    if (field_undone) {
        if (*field_undone != Json(true)) {
            return make_error(ErrorCode::decode, "field 'undone' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<ListAgentsResult>::encode(const ListAgentsResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_agents = encode_value(value.agents);
    if (!encoded_agents) return std::move(encoded_agents).error();
    object.emplace("agents", std::move(encoded_agents).value());
    return Json(std::move(object));
}

Result<ListAgentsResult> Codec<ListAgentsResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ListAgentsResult result{};
    const Json* field_agents = value.find("agents");
    if (!field_agents) {
        return make_error(ErrorCode::decode, "missing required field 'agents'");
    }
    if (field_agents) {
        auto decoded = decode_value<std::vector<AgentRecord>>(*field_agents);
        if (!decoded) return std::move(decoded).error();
        result.agents = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ListTerminalsResult>::encode(const ListTerminalsResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    auto encoded_registry_id = encode_value(value.registry_id);
    if (!encoded_registry_id) return std::move(encoded_registry_id).error();
    object.emplace("registry_id", std::move(encoded_registry_id).value());
    auto encoded_terminal_revision = encode_value(value.terminal_revision);
    if (!encoded_terminal_revision) return std::move(encoded_terminal_revision).error();
    object.emplace("terminal_revision", std::move(encoded_terminal_revision).value());
    auto encoded_terminals = encode_value(value.terminals);
    if (!encoded_terminals) return std::move(encoded_terminals).error();
    object.emplace("terminals", std::move(encoded_terminals).value());
    return Json(std::move(object));
}

Result<ListTerminalsResult> Codec<ListTerminalsResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ListTerminalsResult result{};
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_registry_id = value.find("registry_id");
    if (!field_registry_id) {
        return make_error(ErrorCode::decode, "missing required field 'registry_id'");
    }
    if (field_registry_id) {
        auto decoded = decode_value<std::string>(*field_registry_id);
        if (!decoded) return std::move(decoded).error();
        result.registry_id = std::move(decoded).value();
    }
    const Json* field_terminal_revision = value.find("terminal_revision");
    if (!field_terminal_revision) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_revision'");
    }
    if (field_terminal_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_terminal_revision);
        if (!decoded) return std::move(decoded).error();
        result.terminal_revision = std::move(decoded).value();
    }
    const Json* field_terminals = value.find("terminals");
    if (!field_terminals) {
        return make_error(ErrorCode::decode, "missing required field 'terminals'");
    }
    if (field_terminals) {
        auto decoded = decode_value<std::vector<TerminalRecord>>(*field_terminals);
        if (!decoded) return std::move(decoded).error();
        result.terminals = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<LivePane>::encode(const LivePane& value) {
    (void)value;
    Json::Object object;
    auto encoded_active_tab = encode_value(value.active_tab);
    if (!encoded_active_tab) return std::move(encoded_active_tab).error();
    object.emplace("active_tab", std::move(encoded_active_tab).value());
    if (value.focused_at) {
        auto encoded = encode_value(*value.focused_at);
        if (!encoded) return std::move(encoded).error();
        object.emplace("focused_at", std::move(encoded).value());
    }
    auto encoded_id = encode_value(value.id);
    if (!encoded_id) return std::move(encoded_id).error();
    object.emplace("id", std::move(encoded_id).value());
    if (value.name) {
        auto encoded = encode_value(*value.name);
        if (!encoded) return std::move(encoded).error();
        object.emplace("name", std::move(encoded).value());
    } else {
        object.emplace("name", Json(nullptr));
    }
    if (value.short_id) {
        auto encoded = encode_value(*value.short_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("short_id", std::move(encoded).value());
    }
    auto encoded_tabs = encode_value(value.tabs);
    if (!encoded_tabs) return std::move(encoded_tabs).error();
    object.emplace("tabs", std::move(encoded_tabs).value());
    return Json(std::move(object));
}

Result<LivePane> Codec<LivePane>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    LivePane result{};
    const Json* field_active_tab = value.find("active_tab");
    if (!field_active_tab) {
        return make_error(ErrorCode::decode, "missing required field 'active_tab'");
    }
    if (field_active_tab) {
        auto decoded = decode_value<std::uint64_t>(*field_active_tab);
        if (!decoded) return std::move(decoded).error();
        result.active_tab = std::move(decoded).value();
    }
    const Json* field_focused_at = value.find("focused_at");
    if (field_focused_at) {
        auto decoded = decode_value<std::uint64_t>(*field_focused_at);
        if (!decoded) return std::move(decoded).error();
        result.focused_at = std::move(decoded).value();
    }
    const Json* field_id = value.find("id");
    if (!field_id) {
        return make_error(ErrorCode::decode, "missing required field 'id'");
    }
    if (field_id) {
        auto decoded = decode_value<Id>(*field_id);
        if (!decoded) return std::move(decoded).error();
        result.id = std::move(decoded).value();
    }
    const Json* field_name = value.find("name");
    if (!field_name) {
        return make_error(ErrorCode::decode, "missing required field 'name'");
    }
    if (field_name) {
        if (field_name->is_null()) {
            result.name.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_name);
            if (!decoded) return std::move(decoded).error();
            result.name = std::move(decoded).value();
        }
    }
    const Json* field_short_id = value.find("short_id");
    if (field_short_id) {
        auto decoded = decode_value<std::string>(*field_short_id);
        if (!decoded) return std::move(decoded).error();
        result.short_id = std::move(decoded).value();
    }
    const Json* field_tabs = value.find("tabs");
    if (!field_tabs) {
        return make_error(ErrorCode::decode, "missing required field 'tabs'");
    }
    if (field_tabs) {
        auto decoded = decode_value<std::vector<Tab>>(*field_tabs);
        if (!decoded) return std::move(decoded).error();
        result.tabs = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<MintTerminalRendererResult>::encode(const MintTerminalRendererResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_endpoint = encode_value(value.endpoint);
    if (!encoded_endpoint) return std::move(encoded_endpoint).error();
    object.emplace("endpoint", std::move(encoded_endpoint).value());
    auto encoded_incarnation = encode_value(value.incarnation);
    if (!encoded_incarnation) return std::move(encoded_incarnation).error();
    object.emplace("incarnation", std::move(encoded_incarnation).value());
    auto encoded_protocol_version = encode_value(value.protocol_version);
    if (!encoded_protocol_version) return std::move(encoded_protocol_version).error();
    object.emplace("protocol_version", std::move(encoded_protocol_version).value());
    auto encoded_rights = encode_value(value.rights);
    if (!encoded_rights) return std::move(encoded_rights).error();
    object.emplace("rights", std::move(encoded_rights).value());
    auto encoded_terminal_id = encode_value(value.terminal_id);
    if (!encoded_terminal_id) return std::move(encoded_terminal_id).error();
    object.emplace("terminal_id", std::move(encoded_terminal_id).value());
    auto encoded_token = encode_value(value.token);
    if (!encoded_token) return std::move(encoded_token).error();
    object.emplace("token", std::move(encoded_token).value());
    auto encoded_ttl_ms = encode_value(value.ttl_ms);
    if (!encoded_ttl_ms) return std::move(encoded_ttl_ms).error();
    object.emplace("ttl_ms", std::move(encoded_ttl_ms).value());
    return Json(std::move(object));
}

Result<MintTerminalRendererResult> Codec<MintTerminalRendererResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    MintTerminalRendererResult result{};
    const Json* field_endpoint = value.find("endpoint");
    if (!field_endpoint) {
        return make_error(ErrorCode::decode, "missing required field 'endpoint'");
    }
    if (field_endpoint) {
        auto decoded = decode_value<std::string>(*field_endpoint);
        if (!decoded) return std::move(decoded).error();
        result.endpoint = std::move(decoded).value();
    }
    const Json* field_incarnation = value.find("incarnation");
    if (!field_incarnation) {
        return make_error(ErrorCode::decode, "missing required field 'incarnation'");
    }
    if (field_incarnation) {
        auto decoded = decode_value<std::string>(*field_incarnation);
        if (!decoded) return std::move(decoded).error();
        result.incarnation = std::move(decoded).value();
    }
    const Json* field_protocol_version = value.find("protocol_version");
    if (!field_protocol_version) {
        return make_error(ErrorCode::decode, "missing required field 'protocol_version'");
    }
    if (field_protocol_version) {
        auto decoded = decode_value<std::uint16_t>(*field_protocol_version);
        if (!decoded) return std::move(decoded).error();
        result.protocol_version = std::move(decoded).value();
    }
    const Json* field_rights = value.find("rights");
    if (!field_rights) {
        return make_error(ErrorCode::decode, "missing required field 'rights'");
    }
    if (field_rights) {
        auto decoded = decode_value<std::uint32_t>(*field_rights);
        if (!decoded) return std::move(decoded).error();
        result.rights = std::move(decoded).value();
    }
    const Json* field_terminal_id = value.find("terminal_id");
    if (!field_terminal_id) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_id'");
    }
    if (field_terminal_id) {
        auto decoded = decode_value<std::string>(*field_terminal_id);
        if (!decoded) return std::move(decoded).error();
        result.terminal_id = std::move(decoded).value();
    }
    const Json* field_token = value.find("token");
    if (!field_token) {
        return make_error(ErrorCode::decode, "missing required field 'token'");
    }
    if (field_token) {
        auto decoded = decode_value<std::string>(*field_token);
        if (!decoded) return std::move(decoded).error();
        result.token = std::move(decoded).value();
    }
    const Json* field_ttl_ms = value.find("ttl_ms");
    if (!field_ttl_ms) {
        return make_error(ErrorCode::decode, "missing required field 'ttl_ms'");
    }
    if (field_ttl_ms) {
        auto decoded = decode_value<std::uint64_t>(*field_ttl_ms);
        if (!decoded) return std::move(decoded).error();
        result.ttl_ms = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<MoveTerminalResult>::encode(const MoveTerminalResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_changed = encode_value(value.changed);
    if (!encoded_changed) return std::move(encoded_changed).error();
    object.emplace("changed", std::move(encoded_changed).value());
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    auto encoded_lifecycle = encode_value(value.lifecycle);
    if (!encoded_lifecycle) return std::move(encoded_lifecycle).error();
    object.emplace("lifecycle", std::move(encoded_lifecycle).value());
    if (value.pane) {
        auto encoded = encode_value(*value.pane);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pane", std::move(encoded).value());
    } else {
        object.emplace("pane", Json(nullptr));
    }
    auto encoded_registry_id = encode_value(value.registry_id);
    if (!encoded_registry_id) return std::move(encoded_registry_id).error();
    object.emplace("registry_id", std::move(encoded_registry_id).value());
    auto encoded_replayed = encode_value(value.replayed);
    if (!encoded_replayed) return std::move(encoded_replayed).error();
    object.emplace("replayed", std::move(encoded_replayed).value());
    if (value.screen) {
        auto encoded = encode_value(*value.screen);
        if (!encoded) return std::move(encoded).error();
        object.emplace("screen", std::move(encoded).value());
    } else {
        object.emplace("screen", Json(nullptr));
    }
    if (value.surface) {
        auto encoded = encode_value(*value.surface);
        if (!encoded) return std::move(encoded).error();
        object.emplace("surface", std::move(encoded).value());
    } else {
        object.emplace("surface", Json(nullptr));
    }
    auto encoded_terminal_id = encode_value(value.terminal_id);
    if (!encoded_terminal_id) return std::move(encoded_terminal_id).error();
    object.emplace("terminal_id", std::move(encoded_terminal_id).value());
    if (value.terminal_incarnation) {
        auto encoded = encode_value(*value.terminal_incarnation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal_incarnation", std::move(encoded).value());
    } else {
        object.emplace("terminal_incarnation", Json(nullptr));
    }
    auto encoded_terminal_revision = encode_value(value.terminal_revision);
    if (!encoded_terminal_revision) return std::move(encoded_terminal_revision).error();
    object.emplace("terminal_revision", std::move(encoded_terminal_revision).value());
    if (value.workspace) {
        auto encoded = encode_value(*value.workspace);
        if (!encoded) return std::move(encoded).error();
        object.emplace("workspace", std::move(encoded).value());
    } else {
        object.emplace("workspace", Json(nullptr));
    }
    auto encoded_workspace_key = encode_value(value.workspace_key);
    if (!encoded_workspace_key) return std::move(encoded_workspace_key).error();
    object.emplace("workspace_key", std::move(encoded_workspace_key).value());
    return Json(std::move(object));
}

Result<MoveTerminalResult> Codec<MoveTerminalResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    MoveTerminalResult result{};
    const Json* field_changed = value.find("changed");
    if (!field_changed) {
        return make_error(ErrorCode::decode, "missing required field 'changed'");
    }
    if (field_changed) {
        auto decoded = decode_value<bool>(*field_changed);
        if (!decoded) return std::move(decoded).error();
        result.changed = std::move(decoded).value();
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_lifecycle = value.find("lifecycle");
    if (!field_lifecycle) {
        return make_error(ErrorCode::decode, "missing required field 'lifecycle'");
    }
    if (field_lifecycle) {
        auto decoded = decode_value<TerminalLifecycle>(*field_lifecycle);
        if (!decoded) return std::move(decoded).error();
        result.lifecycle = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        if (field_pane->is_null()) {
            result.pane.reset();
        } else {
            auto decoded = decode_value<Id>(*field_pane);
            if (!decoded) return std::move(decoded).error();
            result.pane = std::move(decoded).value();
        }
    }
    const Json* field_registry_id = value.find("registry_id");
    if (!field_registry_id) {
        return make_error(ErrorCode::decode, "missing required field 'registry_id'");
    }
    if (field_registry_id) {
        auto decoded = decode_value<std::string>(*field_registry_id);
        if (!decoded) return std::move(decoded).error();
        result.registry_id = std::move(decoded).value();
    }
    const Json* field_replayed = value.find("replayed");
    if (!field_replayed) {
        return make_error(ErrorCode::decode, "missing required field 'replayed'");
    }
    if (field_replayed) {
        auto decoded = decode_value<bool>(*field_replayed);
        if (!decoded) return std::move(decoded).error();
        result.replayed = std::move(decoded).value();
    }
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        if (field_screen->is_null()) {
            result.screen.reset();
        } else {
            auto decoded = decode_value<Id>(*field_screen);
            if (!decoded) return std::move(decoded).error();
            result.screen = std::move(decoded).value();
        }
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        if (field_surface->is_null()) {
            result.surface.reset();
        } else {
            auto decoded = decode_value<Id>(*field_surface);
            if (!decoded) return std::move(decoded).error();
            result.surface = std::move(decoded).value();
        }
    }
    const Json* field_terminal_id = value.find("terminal_id");
    if (!field_terminal_id) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_id'");
    }
    if (field_terminal_id) {
        auto decoded = decode_value<std::string>(*field_terminal_id);
        if (!decoded) return std::move(decoded).error();
        result.terminal_id = std::move(decoded).value();
    }
    const Json* field_terminal_incarnation = value.find("terminal_incarnation");
    if (!field_terminal_incarnation) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_incarnation'");
    }
    if (field_terminal_incarnation) {
        if (field_terminal_incarnation->is_null()) {
            result.terminal_incarnation.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_terminal_incarnation);
            if (!decoded) return std::move(decoded).error();
            result.terminal_incarnation = std::move(decoded).value();
        }
    }
    const Json* field_terminal_revision = value.find("terminal_revision");
    if (!field_terminal_revision) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_revision'");
    }
    if (field_terminal_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_terminal_revision);
        if (!decoded) return std::move(decoded).error();
        result.terminal_revision = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        if (field_workspace->is_null()) {
            result.workspace.reset();
        } else {
            auto decoded = decode_value<Id>(*field_workspace);
            if (!decoded) return std::move(decoded).error();
            result.workspace = std::move(decoded).value();
        }
    }
    const Json* field_workspace_key = value.find("workspace_key");
    if (!field_workspace_key) {
        return make_error(ErrorCode::decode, "missing required field 'workspace_key'");
    }
    if (field_workspace_key) {
        auto decoded = decode_value<std::string>(*field_workspace_key);
        if (!decoded) return std::move(decoded).error();
        result.workspace_key = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<NotificationLevel>::encode(const NotificationLevel& value) {
    switch (value) {
        case NotificationLevel::info: return Json(std::string("info"));
        case NotificationLevel::warning: return Json(std::string("warning"));
        case NotificationLevel::error: return Json(std::string("error"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<NotificationLevel> Codec<NotificationLevel>::decode(const Json& value) {
    if (value == Json(std::string("info"))) return NotificationLevel::info;
    if (value == Json(std::string("warning"))) return NotificationLevel::warning;
    if (value == Json(std::string("error"))) return NotificationLevel::error;
    return make_error(ErrorCode::decode, "unknown NotificationLevel value");
}

Result<Json> Codec<NotificationMarker>::encode(const NotificationMarker& value) {
    (void)value;
    Json::Object object;
    auto encoded_level = encode_value(value.level);
    if (!encoded_level) return std::move(encoded_level).error();
    object.emplace("level", std::move(encoded_level).value());
    auto encoded_notification = encode_value(value.notification);
    if (!encoded_notification) return std::move(encoded_notification).error();
    object.emplace("notification", std::move(encoded_notification).value());
    auto encoded_unread = encode_value(value.unread);
    if (!encoded_unread) return std::move(encoded_unread).error();
    object.emplace("unread", std::move(encoded_unread).value());
    return Json(std::move(object));
}

Result<NotificationMarker> Codec<NotificationMarker>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    NotificationMarker result{};
    const Json* field_level = value.find("level");
    if (!field_level) {
        return make_error(ErrorCode::decode, "missing required field 'level'");
    }
    if (field_level) {
        auto decoded = decode_value<NotificationLevel>(*field_level);
        if (!decoded) return std::move(decoded).error();
        result.level = std::move(decoded).value();
    }
    const Json* field_notification = value.find("notification");
    if (!field_notification) {
        return make_error(ErrorCode::decode, "missing required field 'notification'");
    }
    if (field_notification) {
        auto decoded = decode_value<Id>(*field_notification);
        if (!decoded) return std::move(decoded).error();
        result.notification = std::move(decoded).value();
    }
    const Json* field_unread = value.find("unread");
    if (!field_unread) {
        return make_error(ErrorCode::decode, "missing required field 'unread'");
    }
    if (field_unread) {
        auto decoded = decode_value<bool>(*field_unread);
        if (!decoded) return std::move(decoded).error();
        result.unread = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<NotifyResult>::encode(const NotifyResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_notification = encode_value(value.notification);
    if (!encoded_notification) return std::move(encoded_notification).error();
    object.emplace("notification", std::move(encoded_notification).value());
    return Json(std::move(object));
}

Result<NotifyResult> Codec<NotifyResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    NotifyResult result{};
    const Json* field_notification = value.find("notification");
    if (!field_notification) {
        return make_error(ErrorCode::decode, "missing required field 'notification'");
    }
    if (field_notification) {
        auto decoded = decode_value<Id>(*field_notification);
        if (!decoded) return std::move(decoded).error();
        result.notification = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<Pane>::encode(const Pane& value) {
    return encode_value(value.value);
}

Result<Pane> Codec<Pane>::decode(const Json& value) {
    if (auto decoded = decode_value<LivePane>(value); decoded) {
        return Pane{Pane::Variant(std::move(decoded).value())};
    }
    if (auto decoded = decode_value<DeadPane>(value); decoded) {
        return Pane{Pane::Variant(std::move(decoded).value())};
    }
    return make_error(ErrorCode::decode, "value did not match any Pane variant");
}

Result<Json> Codec<PaneDirection>::encode(const PaneDirection& value) {
    switch (value) {
        case PaneDirection::left: return Json(std::string("left"));
        case PaneDirection::right: return Json(std::string("right"));
        case PaneDirection::up: return Json(std::string("up"));
        case PaneDirection::down: return Json(std::string("down"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<PaneDirection> Codec<PaneDirection>::decode(const Json& value) {
    if (value == Json(std::string("left"))) return PaneDirection::left;
    if (value == Json(std::string("right"))) return PaneDirection::right;
    if (value == Json(std::string("up"))) return PaneDirection::up;
    if (value == Json(std::string("down"))) return PaneDirection::down;
    return make_error(ErrorCode::decode, "unknown PaneDirection value");
}

Result<Json> Codec<PaneNeighborResult>::encode(const PaneNeighborResult& value) {
    (void)value;
    Json::Object object;
    if (value.pane) {
        auto encoded = encode_value(*value.pane);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pane", std::move(encoded).value());
    } else {
        object.emplace("pane", Json(nullptr));
    }
    return Json(std::move(object));
}

Result<PaneNeighborResult> Codec<PaneNeighborResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    PaneNeighborResult result{};
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        if (field_pane->is_null()) {
            result.pane.reset();
        } else {
            auto decoded = decode_value<Id>(*field_pane);
            if (!decoded) return std::move(decoded).error();
            result.pane = std::move(decoded).value();
        }
    }
    return result;
}

Result<Json> Codec<PingResult>::encode(const PingResult& value) {
    (void)value;
    Json::Object object;
    if (!value.build_commit.is_absent()) {
        auto encoded = encode_value(value.build_commit);
        if (!encoded) return std::move(encoded).error();
        object.emplace("build_commit", std::move(encoded).value());
    }
    if (!value.ghostty_commit.is_absent()) {
        auto encoded = encode_value(value.ghostty_commit);
        if (!encoded) return std::move(encoded).error();
        object.emplace("ghostty_commit", std::move(encoded).value());
    }
    object.emplace("ok", Json(true));
    auto encoded_protocol = encode_value(value.protocol);
    if (!encoded_protocol) return std::move(encoded_protocol).error();
    object.emplace("protocol", std::move(encoded_protocol).value());
    auto encoded_version = encode_value(value.version);
    if (!encoded_version) return std::move(encoded_version).error();
    object.emplace("version", std::move(encoded_version).value());
    return Json(std::move(object));
}

Result<PingResult> Codec<PingResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    PingResult result{};
    const Json* field_build_commit = value.find("build_commit");
    if (field_build_commit) {
        if (field_build_commit->is_null()) {
            result.build_commit = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_build_commit);
            if (!decoded) return std::move(decoded).error();
            result.build_commit = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_ghostty_commit = value.find("ghostty_commit");
    if (field_ghostty_commit) {
        if (field_ghostty_commit->is_null()) {
            result.ghostty_commit = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_ghostty_commit);
            if (!decoded) return std::move(decoded).error();
            result.ghostty_commit = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_ok = value.find("ok");
    if (!field_ok) {
        return make_error(ErrorCode::decode, "missing required field 'ok'");
    }
    if (field_ok) {
        if (*field_ok != Json(true)) {
            return make_error(ErrorCode::decode, "field 'ok' has the wrong literal value");
        }
    }
    const Json* field_protocol = value.find("protocol");
    if (!field_protocol) {
        return make_error(ErrorCode::decode, "missing required field 'protocol'");
    }
    if (field_protocol) {
        auto decoded = decode_value<std::uint32_t>(*field_protocol);
        if (!decoded) return std::move(decoded).error();
        result.protocol = std::move(decoded).value();
    }
    const Json* field_version = value.find("version");
    if (!field_version) {
        return make_error(ErrorCode::decode, "missing required field 'version'");
    }
    if (field_version) {
        auto decoded = decode_value<std::string>(*field_version);
        if (!decoded) return std::move(decoded).error();
        result.version = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ProcessInfoResult>::encode(const ProcessInfoResult& value) {
    (void)value;
    Json::Object object;
    if (value.command) {
        auto encoded = encode_value(*value.command);
        if (!encoded) return std::move(encoded).error();
        object.emplace("command", std::move(encoded).value());
    } else {
        object.emplace("command", Json(nullptr));
    }
    if (value.cwd) {
        auto encoded = encode_value(*value.cwd);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cwd", std::move(encoded).value());
    } else {
        object.emplace("cwd", Json(nullptr));
    }
    if (value.pid) {
        auto encoded = encode_value(*value.pid);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pid", std::move(encoded).value());
    } else {
        object.emplace("pid", Json(nullptr));
    }
    return Json(std::move(object));
}

Result<ProcessInfoResult> Codec<ProcessInfoResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ProcessInfoResult result{};
    const Json* field_command = value.find("command");
    if (!field_command) {
        return make_error(ErrorCode::decode, "missing required field 'command'");
    }
    if (field_command) {
        if (field_command->is_null()) {
            result.command.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_command);
            if (!decoded) return std::move(decoded).error();
            result.command = std::move(decoded).value();
        }
    }
    const Json* field_cwd = value.find("cwd");
    if (!field_cwd) {
        return make_error(ErrorCode::decode, "missing required field 'cwd'");
    }
    if (field_cwd) {
        if (field_cwd->is_null()) {
            result.cwd.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_cwd);
            if (!decoded) return std::move(decoded).error();
            result.cwd = std::move(decoded).value();
        }
    }
    const Json* field_pid = value.find("pid");
    if (!field_pid) {
        return make_error(ErrorCode::decode, "missing required field 'pid'");
    }
    if (field_pid) {
        if (field_pid->is_null()) {
            result.pid.reset();
        } else {
            auto decoded = decode_value<std::uint32_t>(*field_pid);
            if (!decoded) return std::move(decoded).error();
            result.pid = std::move(decoded).value();
        }
    }
    return result;
}

Result<Json> Codec<ProviderWorkspaceMutationResult>::encode(const ProviderWorkspaceMutationResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_key = encode_value(value.key);
    if (!encoded_key) return std::move(encoded_key).error();
    object.emplace("key", std::move(encoded_key).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    auto encoded_workspace_revision = encode_value(value.workspace_revision);
    if (!encoded_workspace_revision) return std::move(encoded_workspace_revision).error();
    object.emplace("workspace_revision", std::move(encoded_workspace_revision).value());
    return Json(std::move(object));
}

Result<ProviderWorkspaceMutationResult> Codec<ProviderWorkspaceMutationResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ProviderWorkspaceMutationResult result{};
    const Json* field_key = value.find("key");
    if (!field_key) {
        return make_error(ErrorCode::decode, "missing required field 'key'");
    }
    if (field_key) {
        auto decoded = decode_value<std::string>(*field_key);
        if (!decoded) return std::move(decoded).error();
        result.key = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    const Json* field_workspace_revision = value.find("workspace_revision");
    if (!field_workspace_revision) {
        return make_error(ErrorCode::decode, "missing required field 'workspace_revision'");
    }
    if (field_workspace_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_workspace_revision);
        if (!decoded) return std::move(decoded).error();
        result.workspace_revision = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ReadScreenResult>::encode(const ReadScreenResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_text = encode_value(value.text);
    if (!encoded_text) return std::move(encoded_text).error();
    object.emplace("text", std::move(encoded_text).value());
    return Json(std::move(object));
}

Result<ReadScreenResult> Codec<ReadScreenResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ReadScreenResult result{};
    const Json* field_text = value.find("text");
    if (!field_text) {
        return make_error(ErrorCode::decode, "missing required field 'text'");
    }
    if (field_text) {
        auto decoded = decode_value<std::string>(*field_text);
        if (!decoded) return std::move(decoded).error();
        result.text = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ReadScrollbackResult>::encode(const ReadScrollbackResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_epoch = encode_value(value.epoch);
    if (!encoded_epoch) return std::move(encoded_epoch).error();
    object.emplace("epoch", std::move(encoded_epoch).value());
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    auto encoded_start = encode_value(value.start);
    if (!encoded_start) return std::move(encoded_start).error();
    object.emplace("start", std::move(encoded_start).value());
    auto encoded_total = encode_value(value.total);
    if (!encoded_total) return std::move(encoded_total).error();
    object.emplace("total", std::move(encoded_total).value());
    return Json(std::move(object));
}

Result<ReadScrollbackResult> Codec<ReadScrollbackResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ReadScrollbackResult result{};
    const Json* field_epoch = value.find("epoch");
    if (!field_epoch) {
        return make_error(ErrorCode::decode, "missing required field 'epoch'");
    }
    if (field_epoch) {
        auto decoded = decode_value<std::uint64_t>(*field_epoch);
        if (!decoded) return std::move(decoded).error();
        result.epoch = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::vector<RenderRow>>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    const Json* field_start = value.find("start");
    if (!field_start) {
        return make_error(ErrorCode::decode, "missing required field 'start'");
    }
    if (field_start) {
        auto decoded = decode_value<std::uint32_t>(*field_start);
        if (!decoded) return std::move(decoded).error();
        result.start = std::move(decoded).value();
    }
    const Json* field_total = value.find("total");
    if (!field_total) {
        return make_error(ErrorCode::decode, "missing required field 'total'");
    }
    if (field_total) {
        auto decoded = decode_value<std::uint32_t>(*field_total);
        if (!decoded) return std::move(decoded).error();
        result.total = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<RenderCursor>::encode(const RenderCursor& value) {
    (void)value;
    Json::Object object;
    auto encoded_blink = encode_value(value.blink);
    if (!encoded_blink) return std::move(encoded_blink).error();
    object.emplace("blink", std::move(encoded_blink).value());
    if (value.color) {
        auto encoded = encode_value(*value.color);
        if (!encoded) return std::move(encoded).error();
        object.emplace("color", std::move(encoded).value());
    } else {
        object.emplace("color", Json(nullptr));
    }
    auto encoded_style = encode_value(value.style);
    if (!encoded_style) return std::move(encoded_style).error();
    object.emplace("style", std::move(encoded_style).value());
    auto encoded_visible = encode_value(value.visible);
    if (!encoded_visible) return std::move(encoded_visible).error();
    object.emplace("visible", std::move(encoded_visible).value());
    auto encoded_x = encode_value(value.x);
    if (!encoded_x) return std::move(encoded_x).error();
    object.emplace("x", std::move(encoded_x).value());
    auto encoded_y = encode_value(value.y);
    if (!encoded_y) return std::move(encoded_y).error();
    object.emplace("y", std::move(encoded_y).value());
    return Json(std::move(object));
}

Result<RenderCursor> Codec<RenderCursor>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RenderCursor result{};
    const Json* field_blink = value.find("blink");
    if (!field_blink) {
        return make_error(ErrorCode::decode, "missing required field 'blink'");
    }
    if (field_blink) {
        auto decoded = decode_value<bool>(*field_blink);
        if (!decoded) return std::move(decoded).error();
        result.blink = std::move(decoded).value();
    }
    const Json* field_color = value.find("color");
    if (!field_color) {
        return make_error(ErrorCode::decode, "missing required field 'color'");
    }
    if (field_color) {
        if (field_color->is_null()) {
            result.color.reset();
        } else {
            auto decoded = decode_value<ColorHex>(*field_color);
            if (!decoded) return std::move(decoded).error();
            result.color = std::move(decoded).value();
        }
    }
    const Json* field_style = value.find("style");
    if (!field_style) {
        return make_error(ErrorCode::decode, "missing required field 'style'");
    }
    if (field_style) {
        auto decoded = decode_value<CursorStyle>(*field_style);
        if (!decoded) return std::move(decoded).error();
        result.style = std::move(decoded).value();
    }
    const Json* field_visible = value.find("visible");
    if (!field_visible) {
        return make_error(ErrorCode::decode, "missing required field 'visible'");
    }
    if (field_visible) {
        auto decoded = decode_value<bool>(*field_visible);
        if (!decoded) return std::move(decoded).error();
        result.visible = std::move(decoded).value();
    }
    const Json* field_x = value.find("x");
    if (!field_x) {
        return make_error(ErrorCode::decode, "missing required field 'x'");
    }
    if (field_x) {
        auto decoded = decode_value<std::uint16_t>(*field_x);
        if (!decoded) return std::move(decoded).error();
        result.x = std::move(decoded).value();
    }
    const Json* field_y = value.find("y");
    if (!field_y) {
        return make_error(ErrorCode::decode, "missing required field 'y'");
    }
    if (field_y) {
        auto decoded = decode_value<std::uint16_t>(*field_y);
        if (!decoded) return std::move(decoded).error();
        result.y = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<RenderGraphicFormat>::encode(const RenderGraphicFormat& value) {
    switch (value) {
        case RenderGraphicFormat::rgb: return Json(std::string("rgb"));
        case RenderGraphicFormat::rgba: return Json(std::string("rgba"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<RenderGraphicFormat> Codec<RenderGraphicFormat>::decode(const Json& value) {
    if (value == Json(std::string("rgb"))) return RenderGraphicFormat::rgb;
    if (value == Json(std::string("rgba"))) return RenderGraphicFormat::rgba;
    return make_error(ErrorCode::decode, "unknown RenderGraphicFormat value");
}

Result<Json> Codec<RenderGraphicImage>::encode(const RenderGraphicImage& value) {
    (void)value;
    Json::Object object;
    auto encoded_data = encode_value(value.data);
    if (!encoded_data) return std::move(encoded_data).error();
    object.emplace("data", std::move(encoded_data).value());
    auto encoded_format = encode_value(value.format);
    if (!encoded_format) return std::move(encoded_format).error();
    object.emplace("format", std::move(encoded_format).value());
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    auto encoded_height = encode_value(value.height);
    if (!encoded_height) return std::move(encoded_height).error();
    object.emplace("height", std::move(encoded_height).value());
    auto encoded_id = encode_value(value.id);
    if (!encoded_id) return std::move(encoded_id).error();
    object.emplace("id", std::move(encoded_id).value());
    auto encoded_width = encode_value(value.width);
    if (!encoded_width) return std::move(encoded_width).error();
    object.emplace("width", std::move(encoded_width).value());
    return Json(std::move(object));
}

Result<RenderGraphicImage> Codec<RenderGraphicImage>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RenderGraphicImage result{};
    const Json* field_data = value.find("data");
    if (!field_data) {
        return make_error(ErrorCode::decode, "missing required field 'data'");
    }
    if (field_data) {
        auto decoded = decode_value<Base64>(*field_data);
        if (!decoded) return std::move(decoded).error();
        result.data = std::move(decoded).value();
    }
    const Json* field_format = value.find("format");
    if (!field_format) {
        return make_error(ErrorCode::decode, "missing required field 'format'");
    }
    if (field_format) {
        auto decoded = decode_value<RenderGraphicFormat>(*field_format);
        if (!decoded) return std::move(decoded).error();
        result.format = std::move(decoded).value();
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::uint64_t>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_height = value.find("height");
    if (!field_height) {
        return make_error(ErrorCode::decode, "missing required field 'height'");
    }
    if (field_height) {
        auto decoded = decode_value<std::uint32_t>(*field_height);
        if (!decoded) return std::move(decoded).error();
        result.height = std::move(decoded).value();
    }
    const Json* field_id = value.find("id");
    if (!field_id) {
        return make_error(ErrorCode::decode, "missing required field 'id'");
    }
    if (field_id) {
        auto decoded = decode_value<std::uint32_t>(*field_id);
        if (!decoded) return std::move(decoded).error();
        result.id = std::move(decoded).value();
    }
    const Json* field_width = value.find("width");
    if (!field_width) {
        return make_error(ErrorCode::decode, "missing required field 'width'");
    }
    if (field_width) {
        auto decoded = decode_value<std::uint32_t>(*field_width);
        if (!decoded) return std::move(decoded).error();
        result.width = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<RenderGraphicPlacement>::encode(const RenderGraphicPlacement& value) {
    (void)value;
    Json::Object object;
    if (value.anchor_col) {
        auto encoded = encode_value(*value.anchor_col);
        if (!encoded) return std::move(encoded).error();
        object.emplace("anchor_col", std::move(encoded).value());
    }
    if (value.anchor_row) {
        auto encoded = encode_value(*value.anchor_row);
        if (!encoded) return std::move(encoded).error();
        object.emplace("anchor_row", std::move(encoded).value());
    }
    auto encoded_columns = encode_value(value.columns);
    if (!encoded_columns) return std::move(encoded_columns).error();
    object.emplace("columns", std::move(encoded_columns).value());
    auto encoded_grid_cols = encode_value(value.grid_cols);
    if (!encoded_grid_cols) return std::move(encoded_grid_cols).error();
    object.emplace("grid_cols", std::move(encoded_grid_cols).value());
    auto encoded_grid_rows = encode_value(value.grid_rows);
    if (!encoded_grid_rows) return std::move(encoded_grid_rows).error();
    object.emplace("grid_rows", std::move(encoded_grid_rows).value());
    auto encoded_image_id = encode_value(value.image_id);
    if (!encoded_image_id) return std::move(encoded_image_id).error();
    object.emplace("image_id", std::move(encoded_image_id).value());
    auto encoded_ordinal = encode_value(value.ordinal);
    if (!encoded_ordinal) return std::move(encoded_ordinal).error();
    object.emplace("ordinal", std::move(encoded_ordinal).value());
    auto encoded_pixel_height = encode_value(value.pixel_height);
    if (!encoded_pixel_height) return std::move(encoded_pixel_height).error();
    object.emplace("pixel_height", std::move(encoded_pixel_height).value());
    auto encoded_pixel_width = encode_value(value.pixel_width);
    if (!encoded_pixel_width) return std::move(encoded_pixel_width).error();
    object.emplace("pixel_width", std::move(encoded_pixel_width).value());
    auto encoded_placement_id = encode_value(value.placement_id);
    if (!encoded_placement_id) return std::move(encoded_placement_id).error();
    object.emplace("placement_id", std::move(encoded_placement_id).value());
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    auto encoded_source_height = encode_value(value.source_height);
    if (!encoded_source_height) return std::move(encoded_source_height).error();
    object.emplace("source_height", std::move(encoded_source_height).value());
    auto encoded_source_width = encode_value(value.source_width);
    if (!encoded_source_width) return std::move(encoded_source_width).error();
    object.emplace("source_width", std::move(encoded_source_width).value());
    auto encoded_source_x = encode_value(value.source_x);
    if (!encoded_source_x) return std::move(encoded_source_x).error();
    object.emplace("source_x", std::move(encoded_source_x).value());
    auto encoded_source_y = encode_value(value.source_y);
    if (!encoded_source_y) return std::move(encoded_source_y).error();
    object.emplace("source_y", std::move(encoded_source_y).value());
    auto encoded_viewport_col = encode_value(value.viewport_col);
    if (!encoded_viewport_col) return std::move(encoded_viewport_col).error();
    object.emplace("viewport_col", std::move(encoded_viewport_col).value());
    auto encoded_viewport_row = encode_value(value.viewport_row);
    if (!encoded_viewport_row) return std::move(encoded_viewport_row).error();
    object.emplace("viewport_row", std::move(encoded_viewport_row).value());
    auto encoded_viewport_visible = encode_value(value.viewport_visible);
    if (!encoded_viewport_visible) return std::move(encoded_viewport_visible).error();
    object.emplace("viewport_visible", std::move(encoded_viewport_visible).value());
    auto encoded_x_offset = encode_value(value.x_offset);
    if (!encoded_x_offset) return std::move(encoded_x_offset).error();
    object.emplace("x_offset", std::move(encoded_x_offset).value());
    auto encoded_y_offset = encode_value(value.y_offset);
    if (!encoded_y_offset) return std::move(encoded_y_offset).error();
    object.emplace("y_offset", std::move(encoded_y_offset).value());
    auto encoded_z = encode_value(value.z);
    if (!encoded_z) return std::move(encoded_z).error();
    object.emplace("z", std::move(encoded_z).value());
    return Json(std::move(object));
}

Result<RenderGraphicPlacement> Codec<RenderGraphicPlacement>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RenderGraphicPlacement result{};
    const Json* field_anchor_col = value.find("anchor_col");
    if (field_anchor_col) {
        auto decoded = decode_value<std::uint16_t>(*field_anchor_col);
        if (!decoded) return std::move(decoded).error();
        result.anchor_col = std::move(decoded).value();
    }
    const Json* field_anchor_row = value.find("anchor_row");
    if (field_anchor_row) {
        auto decoded = decode_value<std::uint32_t>(*field_anchor_row);
        if (!decoded) return std::move(decoded).error();
        result.anchor_row = std::move(decoded).value();
    }
    const Json* field_columns = value.find("columns");
    if (!field_columns) {
        return make_error(ErrorCode::decode, "missing required field 'columns'");
    }
    if (field_columns) {
        auto decoded = decode_value<std::uint32_t>(*field_columns);
        if (!decoded) return std::move(decoded).error();
        result.columns = std::move(decoded).value();
    }
    const Json* field_grid_cols = value.find("grid_cols");
    if (!field_grid_cols) {
        return make_error(ErrorCode::decode, "missing required field 'grid_cols'");
    }
    if (field_grid_cols) {
        auto decoded = decode_value<std::uint32_t>(*field_grid_cols);
        if (!decoded) return std::move(decoded).error();
        result.grid_cols = std::move(decoded).value();
    }
    const Json* field_grid_rows = value.find("grid_rows");
    if (!field_grid_rows) {
        return make_error(ErrorCode::decode, "missing required field 'grid_rows'");
    }
    if (field_grid_rows) {
        auto decoded = decode_value<std::uint32_t>(*field_grid_rows);
        if (!decoded) return std::move(decoded).error();
        result.grid_rows = std::move(decoded).value();
    }
    const Json* field_image_id = value.find("image_id");
    if (!field_image_id) {
        return make_error(ErrorCode::decode, "missing required field 'image_id'");
    }
    if (field_image_id) {
        auto decoded = decode_value<std::uint32_t>(*field_image_id);
        if (!decoded) return std::move(decoded).error();
        result.image_id = std::move(decoded).value();
    }
    const Json* field_ordinal = value.find("ordinal");
    if (!field_ordinal) {
        return make_error(ErrorCode::decode, "missing required field 'ordinal'");
    }
    if (field_ordinal) {
        auto decoded = decode_value<std::uint32_t>(*field_ordinal);
        if (!decoded) return std::move(decoded).error();
        result.ordinal = std::move(decoded).value();
    }
    const Json* field_pixel_height = value.find("pixel_height");
    if (!field_pixel_height) {
        return make_error(ErrorCode::decode, "missing required field 'pixel_height'");
    }
    if (field_pixel_height) {
        auto decoded = decode_value<std::uint32_t>(*field_pixel_height);
        if (!decoded) return std::move(decoded).error();
        result.pixel_height = std::move(decoded).value();
    }
    const Json* field_pixel_width = value.find("pixel_width");
    if (!field_pixel_width) {
        return make_error(ErrorCode::decode, "missing required field 'pixel_width'");
    }
    if (field_pixel_width) {
        auto decoded = decode_value<std::uint32_t>(*field_pixel_width);
        if (!decoded) return std::move(decoded).error();
        result.pixel_width = std::move(decoded).value();
    }
    const Json* field_placement_id = value.find("placement_id");
    if (!field_placement_id) {
        return make_error(ErrorCode::decode, "missing required field 'placement_id'");
    }
    if (field_placement_id) {
        auto decoded = decode_value<std::uint32_t>(*field_placement_id);
        if (!decoded) return std::move(decoded).error();
        result.placement_id = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::uint32_t>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    const Json* field_source_height = value.find("source_height");
    if (!field_source_height) {
        return make_error(ErrorCode::decode, "missing required field 'source_height'");
    }
    if (field_source_height) {
        auto decoded = decode_value<std::uint32_t>(*field_source_height);
        if (!decoded) return std::move(decoded).error();
        result.source_height = std::move(decoded).value();
    }
    const Json* field_source_width = value.find("source_width");
    if (!field_source_width) {
        return make_error(ErrorCode::decode, "missing required field 'source_width'");
    }
    if (field_source_width) {
        auto decoded = decode_value<std::uint32_t>(*field_source_width);
        if (!decoded) return std::move(decoded).error();
        result.source_width = std::move(decoded).value();
    }
    const Json* field_source_x = value.find("source_x");
    if (!field_source_x) {
        return make_error(ErrorCode::decode, "missing required field 'source_x'");
    }
    if (field_source_x) {
        auto decoded = decode_value<std::uint32_t>(*field_source_x);
        if (!decoded) return std::move(decoded).error();
        result.source_x = std::move(decoded).value();
    }
    const Json* field_source_y = value.find("source_y");
    if (!field_source_y) {
        return make_error(ErrorCode::decode, "missing required field 'source_y'");
    }
    if (field_source_y) {
        auto decoded = decode_value<std::uint32_t>(*field_source_y);
        if (!decoded) return std::move(decoded).error();
        result.source_y = std::move(decoded).value();
    }
    const Json* field_viewport_col = value.find("viewport_col");
    if (!field_viewport_col) {
        return make_error(ErrorCode::decode, "missing required field 'viewport_col'");
    }
    if (field_viewport_col) {
        auto decoded = decode_value<std::int32_t>(*field_viewport_col);
        if (!decoded) return std::move(decoded).error();
        result.viewport_col = std::move(decoded).value();
    }
    const Json* field_viewport_row = value.find("viewport_row");
    if (!field_viewport_row) {
        return make_error(ErrorCode::decode, "missing required field 'viewport_row'");
    }
    if (field_viewport_row) {
        auto decoded = decode_value<std::int32_t>(*field_viewport_row);
        if (!decoded) return std::move(decoded).error();
        result.viewport_row = std::move(decoded).value();
    }
    const Json* field_viewport_visible = value.find("viewport_visible");
    if (!field_viewport_visible) {
        return make_error(ErrorCode::decode, "missing required field 'viewport_visible'");
    }
    if (field_viewport_visible) {
        auto decoded = decode_value<bool>(*field_viewport_visible);
        if (!decoded) return std::move(decoded).error();
        result.viewport_visible = std::move(decoded).value();
    }
    const Json* field_x_offset = value.find("x_offset");
    if (!field_x_offset) {
        return make_error(ErrorCode::decode, "missing required field 'x_offset'");
    }
    if (field_x_offset) {
        auto decoded = decode_value<std::uint32_t>(*field_x_offset);
        if (!decoded) return std::move(decoded).error();
        result.x_offset = std::move(decoded).value();
    }
    const Json* field_y_offset = value.find("y_offset");
    if (!field_y_offset) {
        return make_error(ErrorCode::decode, "missing required field 'y_offset'");
    }
    if (field_y_offset) {
        auto decoded = decode_value<std::uint32_t>(*field_y_offset);
        if (!decoded) return std::move(decoded).error();
        result.y_offset = std::move(decoded).value();
    }
    const Json* field_z = value.find("z");
    if (!field_z) {
        return make_error(ErrorCode::decode, "missing required field 'z'");
    }
    if (field_z) {
        auto decoded = decode_value<std::int32_t>(*field_z);
        if (!decoded) return std::move(decoded).error();
        result.z = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<RenderGraphics>::encode(const RenderGraphics& value) {
    (void)value;
    Json::Object object;
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    if (value.images) {
        auto encoded = encode_value(*value.images);
        if (!encoded) return std::move(encoded).error();
        object.emplace("images", std::move(encoded).value());
    }
    auto encoded_placements = encode_value(value.placements);
    if (!encoded_placements) return std::move(encoded_placements).error();
    object.emplace("placements", std::move(encoded_placements).value());
    if (value.removed_image_ids) {
        auto encoded = encode_value(*value.removed_image_ids);
        if (!encoded) return std::move(encoded).error();
        object.emplace("removed_image_ids", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<RenderGraphics> Codec<RenderGraphics>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RenderGraphics result{};
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::uint64_t>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_images = value.find("images");
    if (field_images) {
        auto decoded = decode_value<std::vector<RenderGraphicImage>>(*field_images);
        if (!decoded) return std::move(decoded).error();
        result.images = std::move(decoded).value();
    }
    const Json* field_placements = value.find("placements");
    if (!field_placements) {
        return make_error(ErrorCode::decode, "missing required field 'placements'");
    }
    if (field_placements) {
        auto decoded = decode_value<std::vector<RenderGraphicPlacement>>(*field_placements);
        if (!decoded) return std::move(decoded).error();
        result.placements = std::move(decoded).value();
    }
    const Json* field_removed_image_ids = value.find("removed_image_ids");
    if (field_removed_image_ids) {
        auto decoded = decode_value<std::vector<std::uint32_t>>(*field_removed_image_ids);
        if (!decoded) return std::move(decoded).error();
        result.removed_image_ids = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<RenderGraphicsDelta>::encode(const RenderGraphicsDelta& value) {
    (void)value;
    Json::Object object;
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    if (value.images) {
        auto encoded = encode_value(*value.images);
        if (!encoded) return std::move(encoded).error();
        object.emplace("images", std::move(encoded).value());
    }
    if (value.placements) {
        auto encoded = encode_value(*value.placements);
        if (!encoded) return std::move(encoded).error();
        object.emplace("placements", std::move(encoded).value());
    }
    if (value.removed_image_ids) {
        auto encoded = encode_value(*value.removed_image_ids);
        if (!encoded) return std::move(encoded).error();
        object.emplace("removed_image_ids", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<RenderGraphicsDelta> Codec<RenderGraphicsDelta>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RenderGraphicsDelta result{};
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::uint64_t>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_images = value.find("images");
    if (field_images) {
        auto decoded = decode_value<std::vector<RenderGraphicImage>>(*field_images);
        if (!decoded) return std::move(decoded).error();
        result.images = std::move(decoded).value();
    }
    const Json* field_placements = value.find("placements");
    if (field_placements) {
        auto decoded = decode_value<std::vector<RenderGraphicPlacement>>(*field_placements);
        if (!decoded) return std::move(decoded).error();
        result.placements = std::move(decoded).value();
    }
    const Json* field_removed_image_ids = value.find("removed_image_ids");
    if (field_removed_image_ids) {
        auto decoded = decode_value<std::vector<std::uint32_t>>(*field_removed_image_ids);
        if (!decoded) return std::move(decoded).error();
        result.removed_image_ids = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<RenderRow>::encode(const RenderRow& value) {
    (void)value;
    Json::Object object;
    auto encoded_row = encode_value(value.row);
    if (!encoded_row) return std::move(encoded_row).error();
    object.emplace("row", std::move(encoded_row).value());
    auto encoded_runs = encode_value(value.runs);
    if (!encoded_runs) return std::move(encoded_runs).error();
    object.emplace("runs", std::move(encoded_runs).value());
    return Json(std::move(object));
}

Result<RenderRow> Codec<RenderRow>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RenderRow result{};
    const Json* field_row = value.find("row");
    if (!field_row) {
        return make_error(ErrorCode::decode, "missing required field 'row'");
    }
    if (field_row) {
        auto decoded = decode_value<std::uint32_t>(*field_row);
        if (!decoded) return std::move(decoded).error();
        result.row = std::move(decoded).value();
    }
    const Json* field_runs = value.find("runs");
    if (!field_runs) {
        return make_error(ErrorCode::decode, "missing required field 'runs'");
    }
    if (field_runs) {
        auto decoded = decode_value<std::vector<RenderRun>>(*field_runs);
        if (!decoded) return std::move(decoded).error();
        result.runs = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<RenderRun>::encode(const RenderRun& value) {
    (void)value;
    Json::Object object;
    auto encoded_attrs = encode_value(value.attrs);
    if (!encoded_attrs) return std::move(encoded_attrs).error();
    object.emplace("attrs", std::move(encoded_attrs).value());
    if (value.bg) {
        auto encoded = encode_value(*value.bg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("bg", std::move(encoded).value());
    } else {
        object.emplace("bg", Json(nullptr));
    }
    if (value.fg) {
        auto encoded = encode_value(*value.fg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("fg", std::move(encoded).value());
    } else {
        object.emplace("fg", Json(nullptr));
    }
    auto encoded_text = encode_value(value.text);
    if (!encoded_text) return std::move(encoded_text).error();
    object.emplace("text", std::move(encoded_text).value());
    if (value.underline) {
        auto encoded = encode_value(*value.underline);
        if (!encoded) return std::move(encoded).error();
        object.emplace("underline", std::move(encoded).value());
    }
    if (value.width_hint) {
        auto encoded = encode_value(*value.width_hint);
        if (!encoded) return std::move(encoded).error();
        object.emplace("width_hint", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<RenderRun> Codec<RenderRun>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RenderRun result{};
    const Json* field_attrs = value.find("attrs");
    if (!field_attrs) {
        return make_error(ErrorCode::decode, "missing required field 'attrs'");
    }
    if (field_attrs) {
        auto decoded = decode_value<std::uint32_t>(*field_attrs);
        if (!decoded) return std::move(decoded).error();
        result.attrs = std::move(decoded).value();
    }
    const Json* field_bg = value.find("bg");
    if (!field_bg) {
        return make_error(ErrorCode::decode, "missing required field 'bg'");
    }
    if (field_bg) {
        if (field_bg->is_null()) {
            result.bg.reset();
        } else {
            auto decoded = decode_value<ColorHex>(*field_bg);
            if (!decoded) return std::move(decoded).error();
            result.bg = std::move(decoded).value();
        }
    }
    const Json* field_fg = value.find("fg");
    if (!field_fg) {
        return make_error(ErrorCode::decode, "missing required field 'fg'");
    }
    if (field_fg) {
        if (field_fg->is_null()) {
            result.fg.reset();
        } else {
            auto decoded = decode_value<ColorHex>(*field_fg);
            if (!decoded) return std::move(decoded).error();
            result.fg = std::move(decoded).value();
        }
    }
    const Json* field_text = value.find("text");
    if (!field_text) {
        return make_error(ErrorCode::decode, "missing required field 'text'");
    }
    if (field_text) {
        auto decoded = decode_value<std::string>(*field_text);
        if (!decoded) return std::move(decoded).error();
        result.text = std::move(decoded).value();
    }
    const Json* field_underline = value.find("underline");
    if (field_underline) {
        auto decoded = decode_value<RenderUnderline>(*field_underline);
        if (!decoded) return std::move(decoded).error();
        result.underline = std::move(decoded).value();
    }
    const Json* field_width_hint = value.find("width_hint");
    if (field_width_hint) {
        auto decoded = decode_value<std::uint16_t>(*field_width_hint);
        if (!decoded) return std::move(decoded).error();
        result.width_hint = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<RenderUnderline>::encode(const RenderUnderline& value) {
    switch (value) {
        case RenderUnderline::single: return Json(std::string("single"));
        case RenderUnderline::double_: return Json(std::string("double"));
        case RenderUnderline::curly: return Json(std::string("curly"));
        case RenderUnderline::dotted: return Json(std::string("dotted"));
        case RenderUnderline::dashed: return Json(std::string("dashed"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<RenderUnderline> Codec<RenderUnderline>::decode(const Json& value) {
    if (value == Json(std::string("single"))) return RenderUnderline::single;
    if (value == Json(std::string("double"))) return RenderUnderline::double_;
    if (value == Json(std::string("curly"))) return RenderUnderline::curly;
    if (value == Json(std::string("dotted"))) return RenderUnderline::dotted;
    if (value == Json(std::string("dashed"))) return RenderUnderline::dashed;
    return make_error(ErrorCode::decode, "unknown RenderUnderline value");
}

Result<Json> Codec<ReportAgentResult>::encode(const ReportAgentResult& value) {
    (void)value;
    Json::Object object;
    if (value.session) {
        auto encoded = encode_value(*value.session);
        if (!encoded) return std::move(encoded).error();
        object.emplace("session", std::move(encoded).value());
    } else {
        object.emplace("session", Json(nullptr));
    }
    auto encoded_source = encode_value(value.source);
    if (!encoded_source) return std::move(encoded_source).error();
    object.emplace("source", std::move(encoded_source).value());
    auto encoded_state = encode_value(value.state);
    if (!encoded_state) return std::move(encoded_state).error();
    object.emplace("state", std::move(encoded_state).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<ReportAgentResult> Codec<ReportAgentResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ReportAgentResult result{};
    const Json* field_session = value.find("session");
    if (!field_session) {
        return make_error(ErrorCode::decode, "missing required field 'session'");
    }
    if (field_session) {
        if (field_session->is_null()) {
            result.session.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_session);
            if (!decoded) return std::move(decoded).error();
            result.session = std::move(decoded).value();
        }
    }
    const Json* field_source = value.find("source");
    if (!field_source) {
        return make_error(ErrorCode::decode, "missing required field 'source'");
    }
    if (field_source) {
        auto decoded = decode_value<AgentReportSource>(*field_source);
        if (!decoded) return std::move(decoded).error();
        result.source = std::move(decoded).value();
    }
    const Json* field_state = value.find("state");
    if (!field_state) {
        return make_error(ErrorCode::decode, "missing required field 'state'");
    }
    if (field_state) {
        auto decoded = decode_value<AgentState>(*field_state);
        if (!decoded) return std::move(decoded).error();
        result.state = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ResizeSurfaceResult>::encode(const ResizeSurfaceResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_accepted = encode_value(value.accepted);
    if (!encoded_accepted) return std::move(encoded_accepted).error();
    object.emplace("accepted", std::move(encoded_accepted).value());
    if (value.reservation_id) {
        auto encoded = encode_value(*value.reservation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("reservation_id", std::move(encoded).value());
    } else {
        object.emplace("reservation_id", Json(nullptr));
    }
    return Json(std::move(object));
}

Result<ResizeSurfaceResult> Codec<ResizeSurfaceResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ResizeSurfaceResult result{};
    const Json* field_accepted = value.find("accepted");
    if (!field_accepted) {
        return make_error(ErrorCode::decode, "missing required field 'accepted'");
    }
    if (field_accepted) {
        auto decoded = decode_value<bool>(*field_accepted);
        if (!decoded) return std::move(decoded).error();
        result.accepted = std::move(decoded).value();
    }
    const Json* field_reservation_id = value.find("reservation_id");
    if (!field_reservation_id) {
        return make_error(ErrorCode::decode, "missing required field 'reservation_id'");
    }
    if (field_reservation_id) {
        if (field_reservation_id->is_null()) {
            result.reservation_id.reset();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_reservation_id);
            if (!decoded) return std::move(decoded).error();
            result.reservation_id = std::move(decoded).value();
        }
    }
    return result;
}

Result<Json> Codec<ResolveTerminalResult>::encode(const ResolveTerminalResult& value) {
    (void)value;
    Json::Object object;
    if (value.exit) {
        auto encoded = encode_value(*value.exit);
        if (!encoded) return std::move(encoded).error();
        object.emplace("exit", std::move(encoded).value());
    } else {
        object.emplace("exit", Json(nullptr));
    }
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    auto encoded_launch_spec = encode_value(value.launch_spec);
    if (!encoded_launch_spec) return std::move(encoded_launch_spec).error();
    object.emplace("launch_spec", std::move(encoded_launch_spec).value());
    auto encoded_lifecycle = encode_value(value.lifecycle);
    if (!encoded_lifecycle) return std::move(encoded_lifecycle).error();
    object.emplace("lifecycle", std::move(encoded_lifecycle).value());
    auto encoded_registry_id = encode_value(value.registry_id);
    if (!encoded_registry_id) return std::move(encoded_registry_id).error();
    object.emplace("registry_id", std::move(encoded_registry_id).value());
    if (value.surface) {
        auto encoded = encode_value(*value.surface);
        if (!encoded) return std::move(encoded).error();
        object.emplace("surface", std::move(encoded).value());
    } else {
        object.emplace("surface", Json(nullptr));
    }
    auto encoded_terminal_id = encode_value(value.terminal_id);
    if (!encoded_terminal_id) return std::move(encoded_terminal_id).error();
    object.emplace("terminal_id", std::move(encoded_terminal_id).value());
    if (value.terminal_incarnation) {
        auto encoded = encode_value(*value.terminal_incarnation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal_incarnation", std::move(encoded).value());
    } else {
        object.emplace("terminal_incarnation", Json(nullptr));
    }
    auto encoded_terminal_revision = encode_value(value.terminal_revision);
    if (!encoded_terminal_revision) return std::move(encoded_terminal_revision).error();
    object.emplace("terminal_revision", std::move(encoded_terminal_revision).value());
    auto encoded_workspace_key = encode_value(value.workspace_key);
    if (!encoded_workspace_key) return std::move(encoded_workspace_key).error();
    object.emplace("workspace_key", std::move(encoded_workspace_key).value());
    return Json(std::move(object));
}

Result<ResolveTerminalResult> Codec<ResolveTerminalResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ResolveTerminalResult result{};
    const Json* field_exit = value.find("exit");
    if (!field_exit) {
        return make_error(ErrorCode::decode, "missing required field 'exit'");
    }
    if (field_exit) {
        if (field_exit->is_null()) {
            result.exit.reset();
        } else {
            auto decoded = decode_value<TerminalExit>(*field_exit);
            if (!decoded) return std::move(decoded).error();
            result.exit = std::move(decoded).value();
        }
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_launch_spec = value.find("launch_spec");
    if (!field_launch_spec) {
        return make_error(ErrorCode::decode, "missing required field 'launch_spec'");
    }
    if (field_launch_spec) {
        auto decoded = decode_value<JsonValue>(*field_launch_spec);
        if (!decoded) return std::move(decoded).error();
        result.launch_spec = std::move(decoded).value();
    }
    const Json* field_lifecycle = value.find("lifecycle");
    if (!field_lifecycle) {
        return make_error(ErrorCode::decode, "missing required field 'lifecycle'");
    }
    if (field_lifecycle) {
        auto decoded = decode_value<TerminalLifecycle>(*field_lifecycle);
        if (!decoded) return std::move(decoded).error();
        result.lifecycle = std::move(decoded).value();
    }
    const Json* field_registry_id = value.find("registry_id");
    if (!field_registry_id) {
        return make_error(ErrorCode::decode, "missing required field 'registry_id'");
    }
    if (field_registry_id) {
        auto decoded = decode_value<std::string>(*field_registry_id);
        if (!decoded) return std::move(decoded).error();
        result.registry_id = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        if (field_surface->is_null()) {
            result.surface.reset();
        } else {
            auto decoded = decode_value<Id>(*field_surface);
            if (!decoded) return std::move(decoded).error();
            result.surface = std::move(decoded).value();
        }
    }
    const Json* field_terminal_id = value.find("terminal_id");
    if (!field_terminal_id) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_id'");
    }
    if (field_terminal_id) {
        auto decoded = decode_value<std::string>(*field_terminal_id);
        if (!decoded) return std::move(decoded).error();
        result.terminal_id = std::move(decoded).value();
    }
    const Json* field_terminal_incarnation = value.find("terminal_incarnation");
    if (!field_terminal_incarnation) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_incarnation'");
    }
    if (field_terminal_incarnation) {
        if (field_terminal_incarnation->is_null()) {
            result.terminal_incarnation.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_terminal_incarnation);
            if (!decoded) return std::move(decoded).error();
            result.terminal_incarnation = std::move(decoded).value();
        }
    }
    const Json* field_terminal_revision = value.find("terminal_revision");
    if (!field_terminal_revision) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_revision'");
    }
    if (field_terminal_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_terminal_revision);
        if (!decoded) return std::move(decoded).error();
        result.terminal_revision = std::move(decoded).value();
    }
    const Json* field_workspace_key = value.find("workspace_key");
    if (!field_workspace_key) {
        return make_error(ErrorCode::decode, "missing required field 'workspace_key'");
    }
    if (field_workspace_key) {
        auto decoded = decode_value<std::string>(*field_workspace_key);
        if (!decoded) return std::move(decoded).error();
        result.workspace_key = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ResourceSelectors>::encode(const ResourceSelectors& value) {
    (void)value;
    Json::Object object;
    if (!value.agent.is_absent()) {
        auto encoded = encode_value(value.agent);
        if (!encoded) return std::move(encoded).error();
        object.emplace("agent", std::move(encoded).value());
    }
    if (!value.browser.is_absent()) {
        auto encoded = encode_value(value.browser);
        if (!encoded) return std::move(encoded).error();
        object.emplace("browser", std::move(encoded).value());
    }
    if (!value.client.is_absent()) {
        auto encoded = encode_value(value.client);
        if (!encoded) return std::move(encoded).error();
        object.emplace("client", std::move(encoded).value());
    }
    if (!value.frontend_projection.is_absent()) {
        auto encoded = encode_value(value.frontend_projection);
        if (!encoded) return std::move(encoded).error();
        object.emplace("frontend_projection", std::move(encoded).value());
    }
    if (!value.machine.is_absent()) {
        auto encoded = encode_value(value.machine);
        if (!encoded) return std::move(encoded).error();
        object.emplace("machine", std::move(encoded).value());
    }
    if (!value.notification.is_absent()) {
        auto encoded = encode_value(value.notification);
        if (!encoded) return std::move(encoded).error();
        object.emplace("notification", std::move(encoded).value());
    }
    if (!value.pairing_request.is_absent()) {
        auto encoded = encode_value(value.pairing_request);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pairing_request", std::move(encoded).value());
    }
    if (!value.pane.is_absent()) {
        auto encoded = encode_value(value.pane);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pane", std::move(encoded).value());
    }
    if (!value.screen.is_absent()) {
        auto encoded = encode_value(value.screen);
        if (!encoded) return std::move(encoded).error();
        object.emplace("screen", std::move(encoded).value());
    }
    if (!value.session.is_absent()) {
        auto encoded = encode_value(value.session);
        if (!encoded) return std::move(encoded).error();
        object.emplace("session", std::move(encoded).value());
    }
    if (!value.sidebar_view.is_absent()) {
        auto encoded = encode_value(value.sidebar_view);
        if (!encoded) return std::move(encoded).error();
        object.emplace("sidebar_view", std::move(encoded).value());
    }
    if (!value.split.is_absent()) {
        auto encoded = encode_value(value.split);
        if (!encoded) return std::move(encoded).error();
        object.emplace("split", std::move(encoded).value());
    }
    if (!value.stream.is_absent()) {
        auto encoded = encode_value(value.stream);
        if (!encoded) return std::move(encoded).error();
        object.emplace("stream", std::move(encoded).value());
    }
    if (!value.tab.is_absent()) {
        auto encoded = encode_value(value.tab);
        if (!encoded) return std::move(encoded).error();
        object.emplace("tab", std::move(encoded).value());
    }
    if (!value.terminal.is_absent()) {
        auto encoded = encode_value(value.terminal);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal", std::move(encoded).value());
    }
    if (!value.workspace.is_absent()) {
        auto encoded = encode_value(value.workspace);
        if (!encoded) return std::move(encoded).error();
        object.emplace("workspace", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<ResourceSelectors> Codec<ResourceSelectors>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ResourceSelectors result{};
    const Json* field_agent = value.find("agent");
    if (field_agent) {
        if (field_agent->is_null()) {
            result.agent = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_agent);
            if (!decoded) return std::move(decoded).error();
            result.agent = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_browser = value.find("browser");
    if (field_browser) {
        if (field_browser->is_null()) {
            result.browser = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_browser);
            if (!decoded) return std::move(decoded).error();
            result.browser = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_client = value.find("client");
    if (field_client) {
        if (field_client->is_null()) {
            result.client = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_client);
            if (!decoded) return std::move(decoded).error();
            result.client = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_frontend_projection = value.find("frontend_projection");
    if (field_frontend_projection) {
        if (field_frontend_projection->is_null()) {
            result.frontend_projection = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_frontend_projection);
            if (!decoded) return std::move(decoded).error();
            result.frontend_projection = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_machine = value.find("machine");
    if (field_machine) {
        if (field_machine->is_null()) {
            result.machine = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_machine);
            if (!decoded) return std::move(decoded).error();
            result.machine = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_notification = value.find("notification");
    if (field_notification) {
        if (field_notification->is_null()) {
            result.notification = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_notification);
            if (!decoded) return std::move(decoded).error();
            result.notification = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_pairing_request = value.find("pairing_request");
    if (field_pairing_request) {
        if (field_pairing_request->is_null()) {
            result.pairing_request = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_pairing_request);
            if (!decoded) return std::move(decoded).error();
            result.pairing_request = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_pane = value.find("pane");
    if (field_pane) {
        if (field_pane->is_null()) {
            result.pane = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_pane);
            if (!decoded) return std::move(decoded).error();
            result.pane = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_screen = value.find("screen");
    if (field_screen) {
        if (field_screen->is_null()) {
            result.screen = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_screen);
            if (!decoded) return std::move(decoded).error();
            result.screen = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_session = value.find("session");
    if (field_session) {
        if (field_session->is_null()) {
            result.session = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_session);
            if (!decoded) return std::move(decoded).error();
            result.session = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_sidebar_view = value.find("sidebar_view");
    if (field_sidebar_view) {
        if (field_sidebar_view->is_null()) {
            result.sidebar_view = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_sidebar_view);
            if (!decoded) return std::move(decoded).error();
            result.sidebar_view = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_split = value.find("split");
    if (field_split) {
        if (field_split->is_null()) {
            result.split = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_split);
            if (!decoded) return std::move(decoded).error();
            result.split = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_stream = value.find("stream");
    if (field_stream) {
        if (field_stream->is_null()) {
            result.stream = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_stream);
            if (!decoded) return std::move(decoded).error();
            result.stream = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_tab = value.find("tab");
    if (field_tab) {
        if (field_tab->is_null()) {
            result.tab = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_tab);
            if (!decoded) return std::move(decoded).error();
            result.tab = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_terminal = value.find("terminal");
    if (field_terminal) {
        if (field_terminal->is_null()) {
            result.terminal = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_terminal);
            if (!decoded) return std::move(decoded).error();
            result.terminal = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_workspace = value.find("workspace");
    if (field_workspace) {
        if (field_workspace->is_null()) {
            result.workspace = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_workspace);
            if (!decoded) return std::move(decoded).error();
            result.workspace = Field<std::string>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<RunResult>::encode(const RunResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_already_exited = encode_value(value.already_exited);
    if (!encoded_already_exited) return std::move(encoded_already_exited).error();
    object.emplace("already_exited", std::move(encoded_already_exited).value());
    if (value.exit) {
        auto encoded = encode_value(*value.exit);
        if (!encoded) return std::move(encoded).error();
        object.emplace("exit", std::move(encoded).value());
    } else {
        object.emplace("exit", Json(nullptr));
    }
    auto encoded_lifecycle = encode_value(value.lifecycle);
    if (!encoded_lifecycle) return std::move(encoded_lifecycle).error();
    object.emplace("lifecycle", std::move(encoded_lifecycle).value());
    if (value.pane) {
        auto encoded = encode_value(*value.pane);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pane", std::move(encoded).value());
    } else {
        object.emplace("pane", Json(nullptr));
    }
    if (value.screen) {
        auto encoded = encode_value(*value.screen);
        if (!encoded) return std::move(encoded).error();
        object.emplace("screen", std::move(encoded).value());
    } else {
        object.emplace("screen", Json(nullptr));
    }
    if (value.surface) {
        auto encoded = encode_value(*value.surface);
        if (!encoded) return std::move(encoded).error();
        object.emplace("surface", std::move(encoded).value());
    } else {
        object.emplace("surface", Json(nullptr));
    }
    auto encoded_terminal_id = encode_value(value.terminal_id);
    if (!encoded_terminal_id) return std::move(encoded_terminal_id).error();
    object.emplace("terminal_id", std::move(encoded_terminal_id).value());
    if (value.terminal_incarnation) {
        auto encoded = encode_value(*value.terminal_incarnation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal_incarnation", std::move(encoded).value());
    } else {
        object.emplace("terminal_incarnation", Json(nullptr));
    }
    auto encoded_terminal_revision = encode_value(value.terminal_revision);
    if (!encoded_terminal_revision) return std::move(encoded_terminal_revision).error();
    object.emplace("terminal_revision", std::move(encoded_terminal_revision).value());
    if (value.workspace) {
        auto encoded = encode_value(*value.workspace);
        if (!encoded) return std::move(encoded).error();
        object.emplace("workspace", std::move(encoded).value());
    } else {
        object.emplace("workspace", Json(nullptr));
    }
    return Json(std::move(object));
}

Result<RunResult> Codec<RunResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RunResult result{};
    const Json* field_already_exited = value.find("already_exited");
    if (!field_already_exited) {
        return make_error(ErrorCode::decode, "missing required field 'already_exited'");
    }
    if (field_already_exited) {
        auto decoded = decode_value<bool>(*field_already_exited);
        if (!decoded) return std::move(decoded).error();
        result.already_exited = std::move(decoded).value();
    }
    const Json* field_exit = value.find("exit");
    if (!field_exit) {
        return make_error(ErrorCode::decode, "missing required field 'exit'");
    }
    if (field_exit) {
        if (field_exit->is_null()) {
            result.exit.reset();
        } else {
            auto decoded = decode_value<TerminalExit>(*field_exit);
            if (!decoded) return std::move(decoded).error();
            result.exit = std::move(decoded).value();
        }
    }
    const Json* field_lifecycle = value.find("lifecycle");
    if (!field_lifecycle) {
        return make_error(ErrorCode::decode, "missing required field 'lifecycle'");
    }
    if (field_lifecycle) {
        auto decoded = decode_value<TerminalLifecycle>(*field_lifecycle);
        if (!decoded) return std::move(decoded).error();
        result.lifecycle = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        if (field_pane->is_null()) {
            result.pane.reset();
        } else {
            auto decoded = decode_value<Id>(*field_pane);
            if (!decoded) return std::move(decoded).error();
            result.pane = std::move(decoded).value();
        }
    }
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        if (field_screen->is_null()) {
            result.screen.reset();
        } else {
            auto decoded = decode_value<Id>(*field_screen);
            if (!decoded) return std::move(decoded).error();
            result.screen = std::move(decoded).value();
        }
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        if (field_surface->is_null()) {
            result.surface.reset();
        } else {
            auto decoded = decode_value<Id>(*field_surface);
            if (!decoded) return std::move(decoded).error();
            result.surface = std::move(decoded).value();
        }
    }
    const Json* field_terminal_id = value.find("terminal_id");
    if (!field_terminal_id) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_id'");
    }
    if (field_terminal_id) {
        auto decoded = decode_value<std::string>(*field_terminal_id);
        if (!decoded) return std::move(decoded).error();
        result.terminal_id = std::move(decoded).value();
    }
    const Json* field_terminal_incarnation = value.find("terminal_incarnation");
    if (!field_terminal_incarnation) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_incarnation'");
    }
    if (field_terminal_incarnation) {
        if (field_terminal_incarnation->is_null()) {
            result.terminal_incarnation.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_terminal_incarnation);
            if (!decoded) return std::move(decoded).error();
            result.terminal_incarnation = std::move(decoded).value();
        }
    }
    const Json* field_terminal_revision = value.find("terminal_revision");
    if (!field_terminal_revision) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_revision'");
    }
    if (field_terminal_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_terminal_revision);
        if (!decoded) return std::move(decoded).error();
        result.terminal_revision = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        if (field_workspace->is_null()) {
            result.workspace.reset();
        } else {
            auto decoded = decode_value<Id>(*field_workspace);
            if (!decoded) return std::move(decoded).error();
            result.workspace = std::move(decoded).value();
        }
    }
    return result;
}

Result<Json> Codec<Screen>::encode(const Screen& value) {
    (void)value;
    Json::Object object;
    auto encoded_active = encode_value(value.active);
    if (!encoded_active) return std::move(encoded_active).error();
    object.emplace("active", std::move(encoded_active).value());
    auto encoded_active_pane = encode_value(value.active_pane);
    if (!encoded_active_pane) return std::move(encoded_active_pane).error();
    object.emplace("active_pane", std::move(encoded_active_pane).value());
    auto encoded_id = encode_value(value.id);
    if (!encoded_id) return std::move(encoded_id).error();
    object.emplace("id", std::move(encoded_id).value());
    auto encoded_layout = encode_value(value.layout);
    if (!encoded_layout) return std::move(encoded_layout).error();
    object.emplace("layout", std::move(encoded_layout).value());
    if (value.name) {
        auto encoded = encode_value(*value.name);
        if (!encoded) return std::move(encoded).error();
        object.emplace("name", std::move(encoded).value());
    } else {
        object.emplace("name", Json(nullptr));
    }
    auto encoded_panes = encode_value(value.panes);
    if (!encoded_panes) return std::move(encoded_panes).error();
    object.emplace("panes", std::move(encoded_panes).value());
    if (value.short_id) {
        auto encoded = encode_value(*value.short_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("short_id", std::move(encoded).value());
    }
    if (value.zoomed_pane) {
        auto encoded = encode_value(*value.zoomed_pane);
        if (!encoded) return std::move(encoded).error();
        object.emplace("zoomed_pane", std::move(encoded).value());
    } else {
        object.emplace("zoomed_pane", Json(nullptr));
    }
    return Json(std::move(object));
}

Result<Screen> Codec<Screen>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    Screen result{};
    const Json* field_active = value.find("active");
    if (!field_active) {
        return make_error(ErrorCode::decode, "missing required field 'active'");
    }
    if (field_active) {
        auto decoded = decode_value<bool>(*field_active);
        if (!decoded) return std::move(decoded).error();
        result.active = std::move(decoded).value();
    }
    const Json* field_active_pane = value.find("active_pane");
    if (!field_active_pane) {
        return make_error(ErrorCode::decode, "missing required field 'active_pane'");
    }
    if (field_active_pane) {
        auto decoded = decode_value<Id>(*field_active_pane);
        if (!decoded) return std::move(decoded).error();
        result.active_pane = std::move(decoded).value();
    }
    const Json* field_id = value.find("id");
    if (!field_id) {
        return make_error(ErrorCode::decode, "missing required field 'id'");
    }
    if (field_id) {
        auto decoded = decode_value<Id>(*field_id);
        if (!decoded) return std::move(decoded).error();
        result.id = std::move(decoded).value();
    }
    const Json* field_layout = value.find("layout");
    if (!field_layout) {
        return make_error(ErrorCode::decode, "missing required field 'layout'");
    }
    if (field_layout) {
        auto decoded = decode_value<Layout>(*field_layout);
        if (!decoded) return std::move(decoded).error();
        result.layout = std::move(decoded).value();
    }
    const Json* field_name = value.find("name");
    if (!field_name) {
        return make_error(ErrorCode::decode, "missing required field 'name'");
    }
    if (field_name) {
        if (field_name->is_null()) {
            result.name.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_name);
            if (!decoded) return std::move(decoded).error();
            result.name = std::move(decoded).value();
        }
    }
    const Json* field_panes = value.find("panes");
    if (!field_panes) {
        return make_error(ErrorCode::decode, "missing required field 'panes'");
    }
    if (field_panes) {
        auto decoded = decode_value<std::vector<Pane>>(*field_panes);
        if (!decoded) return std::move(decoded).error();
        result.panes = std::move(decoded).value();
    }
    const Json* field_short_id = value.find("short_id");
    if (field_short_id) {
        auto decoded = decode_value<std::string>(*field_short_id);
        if (!decoded) return std::move(decoded).error();
        result.short_id = std::move(decoded).value();
    }
    const Json* field_zoomed_pane = value.find("zoomed_pane");
    if (!field_zoomed_pane) {
        return make_error(ErrorCode::decode, "missing required field 'zoomed_pane'");
    }
    if (field_zoomed_pane) {
        if (field_zoomed_pane->is_null()) {
            result.zoomed_pane.reset();
        } else {
            auto decoded = decode_value<Id>(*field_zoomed_pane);
            if (!decoded) return std::move(decoded).error();
            result.zoomed_pane = std::move(decoded).value();
        }
    }
    return result;
}

Result<Json> Codec<SetCellPixelsResult>::encode(const SetCellPixelsResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_failures = encode_value(value.failures);
    if (!encoded_failures) return std::move(encoded_failures).error();
    object.emplace("failures", std::move(encoded_failures).value());
    auto encoded_resizes = encode_value(value.resizes);
    if (!encoded_resizes) return std::move(encoded_resizes).error();
    object.emplace("resizes", std::move(encoded_resizes).value());
    return Json(std::move(object));
}

Result<SetCellPixelsResult> Codec<SetCellPixelsResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SetCellPixelsResult result{};
    const Json* field_failures = value.find("failures");
    if (!field_failures) {
        return make_error(ErrorCode::decode, "missing required field 'failures'");
    }
    if (field_failures) {
        auto decoded = decode_value<std::vector<CellPixelFailure>>(*field_failures);
        if (!decoded) return std::move(decoded).error();
        result.failures = std::move(decoded).value();
    }
    const Json* field_resizes = value.find("resizes");
    if (!field_resizes) {
        return make_error(ErrorCode::decode, "missing required field 'resizes'");
    }
    if (field_resizes) {
        auto decoded = decode_value<std::vector<CellPixelResize>>(*field_resizes);
        if (!decoded) return std::move(decoded).error();
        result.resizes = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ShutdownDaemonResult>::encode(const ShutdownDaemonResult& value) {
    (void)value;
    Json::Object object;
    object.emplace("accepted", Json(true));
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    auto encoded_pid = encode_value(value.pid);
    if (!encoded_pid) return std::move(encoded_pid).error();
    object.emplace("pid", std::move(encoded_pid).value());
    return Json(std::move(object));
}

Result<ShutdownDaemonResult> Codec<ShutdownDaemonResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ShutdownDaemonResult result{};
    const Json* field_accepted = value.find("accepted");
    if (!field_accepted) {
        return make_error(ErrorCode::decode, "missing required field 'accepted'");
    }
    if (field_accepted) {
        if (*field_accepted != Json(true)) {
            return make_error(ErrorCode::decode, "field 'accepted' has the wrong literal value");
        }
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_pid = value.find("pid");
    if (!field_pid) {
        return make_error(ErrorCode::decode, "missing required field 'pid'");
    }
    if (field_pid) {
        auto decoded = decode_value<std::uint32_t>(*field_pid);
        if (!decoded) return std::move(decoded).error();
        result.pid = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<SidebarPluginResult>::encode(const SidebarPluginResult& value) {
    (void)value;
    Json::Object object;
    if (value.error) {
        auto encoded = encode_value(*value.error);
        if (!encoded) return std::move(encoded).error();
        object.emplace("error", std::move(encoded).value());
    } else {
        object.emplace("error", Json(nullptr));
    }
    if (value.retry_after_ms) {
        auto encoded = encode_value(*value.retry_after_ms);
        if (!encoded) return std::move(encoded).error();
        object.emplace("retry_after_ms", std::move(encoded).value());
    } else {
        object.emplace("retry_after_ms", Json(nullptr));
    }
    if (value.surface) {
        auto encoded = encode_value(*value.surface);
        if (!encoded) return std::move(encoded).error();
        object.emplace("surface", std::move(encoded).value());
    } else {
        object.emplace("surface", Json(nullptr));
    }
    return Json(std::move(object));
}

Result<SidebarPluginResult> Codec<SidebarPluginResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SidebarPluginResult result{};
    const Json* field_error = value.find("error");
    if (!field_error) {
        return make_error(ErrorCode::decode, "missing required field 'error'");
    }
    if (field_error) {
        if (field_error->is_null()) {
            result.error.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_error);
            if (!decoded) return std::move(decoded).error();
            result.error = std::move(decoded).value();
        }
    }
    const Json* field_retry_after_ms = value.find("retry_after_ms");
    if (!field_retry_after_ms) {
        return make_error(ErrorCode::decode, "missing required field 'retry_after_ms'");
    }
    if (field_retry_after_ms) {
        if (field_retry_after_ms->is_null()) {
            result.retry_after_ms.reset();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_retry_after_ms);
            if (!decoded) return std::move(decoded).error();
            result.retry_after_ms = std::move(decoded).value();
        }
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        if (field_surface->is_null()) {
            result.surface.reset();
        } else {
            auto decoded = decode_value<Id>(*field_surface);
            if (!decoded) return std::move(decoded).error();
            result.surface = std::move(decoded).value();
        }
    }
    return result;
}

Result<Json> Codec<Size>::encode(const Size& value) {
    (void)value;
    Json::Object object;
    auto encoded_cols = encode_value(value.cols);
    if (!encoded_cols) return std::move(encoded_cols).error();
    object.emplace("cols", std::move(encoded_cols).value());
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    return Json(std::move(object));
}

Result<Size> Codec<Size>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    Size result{};
    const Json* field_cols = value.find("cols");
    if (!field_cols) {
        return make_error(ErrorCode::decode, "missing required field 'cols'");
    }
    if (field_cols) {
        auto decoded = decode_value<std::uint16_t>(*field_cols);
        if (!decoded) return std::move(decoded).error();
        result.cols = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::uint16_t>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<SplitDirection>::encode(const SplitDirection& value) {
    switch (value) {
        case SplitDirection::right: return Json(std::string("right"));
        case SplitDirection::down: return Json(std::string("down"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<SplitDirection> Codec<SplitDirection>::decode(const Json& value) {
    if (value == Json(std::string("right"))) return SplitDirection::right;
    if (value == Json(std::string("down"))) return SplitDirection::down;
    return make_error(ErrorCode::decode, "unknown SplitDirection value");
}

Result<Json> Codec<SurfaceResult>::encode(const SurfaceResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    if (!value.terminal_id.is_absent()) {
        auto encoded = encode_value(value.terminal_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal_id", std::move(encoded).value());
    }
    if (!value.terminal_incarnation.is_absent()) {
        auto encoded = encode_value(value.terminal_incarnation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal_incarnation", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<SurfaceResult> Codec<SurfaceResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SurfaceResult result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_terminal_id = value.find("terminal_id");
    if (field_terminal_id) {
        if (field_terminal_id->is_null()) {
            result.terminal_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_terminal_id);
            if (!decoded) return std::move(decoded).error();
            result.terminal_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_terminal_incarnation = value.find("terminal_incarnation");
    if (field_terminal_incarnation) {
        if (field_terminal_incarnation->is_null()) {
            result.terminal_incarnation = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_terminal_incarnation);
            if (!decoded) return std::move(decoded).error();
            result.terminal_incarnation = Field<std::string>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<Tab>::encode(const Tab& value) {
    (void)value;
    Json::Object object;
    if (!value.browser_error.is_absent()) {
        auto encoded = encode_value(value.browser_error);
        if (!encoded) return std::move(encoded).error();
        object.emplace("browser_error", std::move(encoded).value());
    }
    if (!value.browser_frames_stalled.is_absent()) {
        auto encoded = encode_value(value.browser_frames_stalled);
        if (!encoded) return std::move(encoded).error();
        object.emplace("browser_frames_stalled", std::move(encoded).value());
    }
    if (value.browser_source) {
        auto encoded = encode_value(*value.browser_source);
        if (!encoded) return std::move(encoded).error();
        object.emplace("browser_source", std::move(encoded).value());
    } else {
        object.emplace("browser_source", Json(nullptr));
    }
    if (!value.browser_status.is_absent()) {
        auto encoded = encode_value(value.browser_status);
        if (!encoded) return std::move(encoded).error();
        object.emplace("browser_status", std::move(encoded).value());
    }
    auto encoded_dead = encode_value(value.dead);
    if (!encoded_dead) return std::move(encoded_dead).error();
    object.emplace("dead", std::move(encoded_dead).value());
    auto encoded_kind = encode_value(value.kind);
    if (!encoded_kind) return std::move(encoded_kind).error();
    object.emplace("kind", std::move(encoded_kind).value());
    if (value.name) {
        auto encoded = encode_value(*value.name);
        if (!encoded) return std::move(encoded).error();
        object.emplace("name", std::move(encoded).value());
    } else {
        object.emplace("name", Json(nullptr));
    }
    if (!value.notification.is_absent()) {
        auto encoded = encode_value(value.notification);
        if (!encoded) return std::move(encoded).error();
        object.emplace("notification", std::move(encoded).value());
    }
    if (value.short_id) {
        auto encoded = encode_value(*value.short_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("short_id", std::move(encoded).value());
    }
    if (value.size) {
        auto encoded = encode_value(*value.size);
        if (!encoded) return std::move(encoded).error();
        object.emplace("size", std::move(encoded).value());
    } else {
        object.emplace("size", Json(nullptr));
    }
    if (value.supports_clear_history_key_fallback) {
        auto encoded = encode_value(*value.supports_clear_history_key_fallback);
        if (!encoded) return std::move(encoded).error();
        object.emplace("supports_clear_history_key_fallback", std::move(encoded).value());
    }
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    if (!value.terminal_id.is_absent()) {
        auto encoded = encode_value(value.terminal_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal_id", std::move(encoded).value());
    }
    if (!value.terminal_incarnation.is_absent()) {
        auto encoded = encode_value(value.terminal_incarnation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal_incarnation", std::move(encoded).value());
    }
    if (!value.terminal_resource_id.is_absent()) {
        auto encoded = encode_value(value.terminal_resource_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal_resource_id", std::move(encoded).value());
    }
    auto encoded_title = encode_value(value.title);
    if (!encoded_title) return std::move(encoded_title).error();
    object.emplace("title", std::move(encoded_title).value());
    return Json(std::move(object));
}

Result<Tab> Codec<Tab>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    Tab result{};
    const Json* field_browser_error = value.find("browser_error");
    if (field_browser_error) {
        if (field_browser_error->is_null()) {
            result.browser_error = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_browser_error);
            if (!decoded) return std::move(decoded).error();
            result.browser_error = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_browser_frames_stalled = value.find("browser_frames_stalled");
    if (field_browser_frames_stalled) {
        if (field_browser_frames_stalled->is_null()) {
            result.browser_frames_stalled = Field<bool>::null();
        } else {
            auto decoded = decode_value<bool>(*field_browser_frames_stalled);
            if (!decoded) return std::move(decoded).error();
            result.browser_frames_stalled = Field<bool>(std::move(decoded).value());
        }
    }
    const Json* field_browser_source = value.find("browser_source");
    if (!field_browser_source) {
        return make_error(ErrorCode::decode, "missing required field 'browser_source'");
    }
    if (field_browser_source) {
        if (field_browser_source->is_null()) {
            result.browser_source.reset();
        } else {
            auto decoded = decode_value<TabBrowserSource>(*field_browser_source);
            if (!decoded) return std::move(decoded).error();
            result.browser_source = std::move(decoded).value();
        }
    }
    const Json* field_browser_status = value.find("browser_status");
    if (field_browser_status) {
        if (field_browser_status->is_null()) {
            result.browser_status = Field<TabBrowserStatus>::null();
        } else {
            auto decoded = decode_value<TabBrowserStatus>(*field_browser_status);
            if (!decoded) return std::move(decoded).error();
            result.browser_status = Field<TabBrowserStatus>(std::move(decoded).value());
        }
    }
    const Json* field_dead = value.find("dead");
    if (!field_dead) {
        return make_error(ErrorCode::decode, "missing required field 'dead'");
    }
    if (field_dead) {
        auto decoded = decode_value<bool>(*field_dead);
        if (!decoded) return std::move(decoded).error();
        result.dead = std::move(decoded).value();
    }
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        auto decoded = decode_value<TabKind>(*field_kind);
        if (!decoded) return std::move(decoded).error();
        result.kind = std::move(decoded).value();
    }
    const Json* field_name = value.find("name");
    if (!field_name) {
        return make_error(ErrorCode::decode, "missing required field 'name'");
    }
    if (field_name) {
        if (field_name->is_null()) {
            result.name.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_name);
            if (!decoded) return std::move(decoded).error();
            result.name = std::move(decoded).value();
        }
    }
    const Json* field_notification = value.find("notification");
    if (field_notification) {
        if (field_notification->is_null()) {
            result.notification = Field<NotificationMarker>::null();
        } else {
            auto decoded = decode_value<NotificationMarker>(*field_notification);
            if (!decoded) return std::move(decoded).error();
            result.notification = Field<NotificationMarker>(std::move(decoded).value());
        }
    }
    const Json* field_short_id = value.find("short_id");
    if (field_short_id) {
        auto decoded = decode_value<std::string>(*field_short_id);
        if (!decoded) return std::move(decoded).error();
        result.short_id = std::move(decoded).value();
    }
    const Json* field_size = value.find("size");
    if (!field_size) {
        return make_error(ErrorCode::decode, "missing required field 'size'");
    }
    if (field_size) {
        if (field_size->is_null()) {
            result.size.reset();
        } else {
            auto decoded = decode_value<Size>(*field_size);
            if (!decoded) return std::move(decoded).error();
            result.size = std::move(decoded).value();
        }
    }
    const Json* field_supports_clear_history_key_fallback = value.find("supports_clear_history_key_fallback");
    if (field_supports_clear_history_key_fallback) {
        auto decoded = decode_value<bool>(*field_supports_clear_history_key_fallback);
        if (!decoded) return std::move(decoded).error();
        result.supports_clear_history_key_fallback = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_terminal_id = value.find("terminal_id");
    if (field_terminal_id) {
        if (field_terminal_id->is_null()) {
            result.terminal_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_terminal_id);
            if (!decoded) return std::move(decoded).error();
            result.terminal_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_terminal_incarnation = value.find("terminal_incarnation");
    if (field_terminal_incarnation) {
        if (field_terminal_incarnation->is_null()) {
            result.terminal_incarnation = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_terminal_incarnation);
            if (!decoded) return std::move(decoded).error();
            result.terminal_incarnation = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_terminal_resource_id = value.find("terminal_resource_id");
    if (field_terminal_resource_id) {
        if (field_terminal_resource_id->is_null()) {
            result.terminal_resource_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_terminal_resource_id);
            if (!decoded) return std::move(decoded).error();
            result.terminal_resource_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_title = value.find("title");
    if (!field_title) {
        return make_error(ErrorCode::decode, "missing required field 'title'");
    }
    if (field_title) {
        auto decoded = decode_value<std::string>(*field_title);
        if (!decoded) return std::move(decoded).error();
        result.title = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<TerminalColors>::encode(const TerminalColors& value) {
    (void)value;
    Json::Object object;
    if (value.bg) {
        auto encoded = encode_value(*value.bg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("bg", std::move(encoded).value());
    } else {
        object.emplace("bg", Json(nullptr));
    }
    if (!value.cursor.is_absent()) {
        auto encoded = encode_value(value.cursor);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cursor", std::move(encoded).value());
    }
    if (!value.cursor_blink.is_absent()) {
        auto encoded = encode_value(value.cursor_blink);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cursor_blink", std::move(encoded).value());
    }
    if (!value.cursor_style.is_absent()) {
        auto encoded = encode_value(value.cursor_style);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cursor_style", std::move(encoded).value());
    }
    if (value.fg) {
        auto encoded = encode_value(*value.fg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("fg", std::move(encoded).value());
    } else {
        object.emplace("fg", Json(nullptr));
    }
    if (value.palette) {
        auto encoded = encode_value(*value.palette);
        if (!encoded) return std::move(encoded).error();
        object.emplace("palette", std::move(encoded).value());
    }
    if (value.selection_bg) {
        auto encoded = encode_value(*value.selection_bg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("selection_bg", std::move(encoded).value());
    } else {
        object.emplace("selection_bg", Json(nullptr));
    }
    if (value.selection_fg) {
        auto encoded = encode_value(*value.selection_fg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("selection_fg", std::move(encoded).value());
    } else {
        object.emplace("selection_fg", Json(nullptr));
    }
    return Json(std::move(object));
}

Result<TerminalColors> Codec<TerminalColors>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TerminalColors result{};
    const Json* field_bg = value.find("bg");
    if (!field_bg) {
        return make_error(ErrorCode::decode, "missing required field 'bg'");
    }
    if (field_bg) {
        if (field_bg->is_null()) {
            result.bg.reset();
        } else {
            auto decoded = decode_value<ColorHex>(*field_bg);
            if (!decoded) return std::move(decoded).error();
            result.bg = std::move(decoded).value();
        }
    }
    const Json* field_cursor = value.find("cursor");
    if (field_cursor) {
        if (field_cursor->is_null()) {
            result.cursor = Field<ColorHex>::null();
        } else {
            auto decoded = decode_value<ColorHex>(*field_cursor);
            if (!decoded) return std::move(decoded).error();
            result.cursor = Field<ColorHex>(std::move(decoded).value());
        }
    }
    const Json* field_cursor_blink = value.find("cursor_blink");
    if (field_cursor_blink) {
        if (field_cursor_blink->is_null()) {
            result.cursor_blink = Field<bool>::null();
        } else {
            auto decoded = decode_value<bool>(*field_cursor_blink);
            if (!decoded) return std::move(decoded).error();
            result.cursor_blink = Field<bool>(std::move(decoded).value());
        }
    }
    const Json* field_cursor_style = value.find("cursor_style");
    if (field_cursor_style) {
        if (field_cursor_style->is_null()) {
            result.cursor_style = Field<CursorStyle>::null();
        } else {
            auto decoded = decode_value<CursorStyle>(*field_cursor_style);
            if (!decoded) return std::move(decoded).error();
            result.cursor_style = Field<CursorStyle>(std::move(decoded).value());
        }
    }
    const Json* field_fg = value.find("fg");
    if (!field_fg) {
        return make_error(ErrorCode::decode, "missing required field 'fg'");
    }
    if (field_fg) {
        if (field_fg->is_null()) {
            result.fg.reset();
        } else {
            auto decoded = decode_value<ColorHex>(*field_fg);
            if (!decoded) return std::move(decoded).error();
            result.fg = std::move(decoded).value();
        }
    }
    const Json* field_palette = value.find("palette");
    if (field_palette) {
        auto decoded = decode_value<std::map<std::string, ColorHex, std::less<>>>(*field_palette);
        if (!decoded) return std::move(decoded).error();
        result.palette = std::move(decoded).value();
    }
    const Json* field_selection_bg = value.find("selection_bg");
    if (!field_selection_bg) {
        return make_error(ErrorCode::decode, "missing required field 'selection_bg'");
    }
    if (field_selection_bg) {
        if (field_selection_bg->is_null()) {
            result.selection_bg.reset();
        } else {
            auto decoded = decode_value<ColorHex>(*field_selection_bg);
            if (!decoded) return std::move(decoded).error();
            result.selection_bg = std::move(decoded).value();
        }
    }
    const Json* field_selection_fg = value.find("selection_fg");
    if (!field_selection_fg) {
        return make_error(ErrorCode::decode, "missing required field 'selection_fg'");
    }
    if (field_selection_fg) {
        if (field_selection_fg->is_null()) {
            result.selection_fg.reset();
        } else {
            auto decoded = decode_value<ColorHex>(*field_selection_fg);
            if (!decoded) return std::move(decoded).error();
            result.selection_fg = std::move(decoded).value();
        }
    }
    return result;
}

Result<Json> Codec<TerminalEventsResult>::encode(const TerminalEventsResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_events = encode_value(value.events);
    if (!encoded_events) return std::move(encoded_events).error();
    object.emplace("events", std::move(encoded_events).value());
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    auto encoded_registry_id = encode_value(value.registry_id);
    if (!encoded_registry_id) return std::move(encoded_registry_id).error();
    object.emplace("registry_id", std::move(encoded_registry_id).value());
    auto encoded_terminal_revision = encode_value(value.terminal_revision);
    if (!encoded_terminal_revision) return std::move(encoded_terminal_revision).error();
    object.emplace("terminal_revision", std::move(encoded_terminal_revision).value());
    return Json(std::move(object));
}

Result<TerminalEventsResult> Codec<TerminalEventsResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TerminalEventsResult result{};
    const Json* field_events = value.find("events");
    if (!field_events) {
        return make_error(ErrorCode::decode, "missing required field 'events'");
    }
    if (field_events) {
        auto decoded = decode_value<std::vector<TerminalRegistryEvent>>(*field_events);
        if (!decoded) return std::move(decoded).error();
        result.events = std::move(decoded).value();
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_registry_id = value.find("registry_id");
    if (!field_registry_id) {
        return make_error(ErrorCode::decode, "missing required field 'registry_id'");
    }
    if (field_registry_id) {
        auto decoded = decode_value<std::string>(*field_registry_id);
        if (!decoded) return std::move(decoded).error();
        result.registry_id = std::move(decoded).value();
    }
    const Json* field_terminal_revision = value.find("terminal_revision");
    if (!field_terminal_revision) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_revision'");
    }
    if (field_terminal_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_terminal_revision);
        if (!decoded) return std::move(decoded).error();
        result.terminal_revision = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<TerminalExit>::encode(const TerminalExit& value) {
    (void)value;
    Json::Object object;
    auto encoded_exited_at_ms = encode_value(value.exited_at_ms);
    if (!encoded_exited_at_ms) return std::move(encoded_exited_at_ms).error();
    object.emplace("exited_at_ms", std::move(encoded_exited_at_ms).value());
    auto encoded_outcome = encode_value(value.outcome);
    if (!encoded_outcome) return std::move(encoded_outcome).error();
    object.emplace("outcome", std::move(encoded_outcome).value());
    return Json(std::move(object));
}

Result<TerminalExit> Codec<TerminalExit>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TerminalExit result{};
    const Json* field_exited_at_ms = value.find("exited_at_ms");
    if (!field_exited_at_ms) {
        return make_error(ErrorCode::decode, "missing required field 'exited_at_ms'");
    }
    if (field_exited_at_ms) {
        auto decoded = decode_value<std::uint64_t>(*field_exited_at_ms);
        if (!decoded) return std::move(decoded).error();
        result.exited_at_ms = std::move(decoded).value();
    }
    const Json* field_outcome = value.find("outcome");
    if (!field_outcome) {
        return make_error(ErrorCode::decode, "missing required field 'outcome'");
    }
    if (field_outcome) {
        auto decoded = decode_value<TerminalExitOutcome>(*field_outcome);
        if (!decoded) return std::move(decoded).error();
        result.outcome = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<TerminalExitOutcome>::encode(const TerminalExitOutcome& value) {
    return encode_value(value.value);
}

Result<TerminalExitOutcome> Codec<TerminalExitOutcome>::decode(const Json& value) {
    auto tag = require_string(value, "kind");
    if (!tag) return std::move(tag).error();
    if (tag.value() == "exit") {
        auto decoded = decode_value<TerminalExitOutcomeExit>(value);
        if (!decoded) return std::move(decoded).error();
        return TerminalExitOutcome{TerminalExitOutcome::Variant(std::move(decoded).value())};
    }
    if (tag.value() == "signal") {
        auto decoded = decode_value<TerminalExitOutcomeSignal>(value);
        if (!decoded) return std::move(decoded).error();
        return TerminalExitOutcome{TerminalExitOutcome::Variant(std::move(decoded).value())};
    }
    if (tag.value() == "unknown") {
        auto decoded = decode_value<TerminalExitOutcomeUnknown>(value);
        if (!decoded) return std::move(decoded).error();
        return TerminalExitOutcome{TerminalExitOutcome::Variant(std::move(decoded).value())};
    }
    return make_error(ErrorCode::decode, "unknown TerminalExitOutcome tag");
}

Result<Json> Codec<TerminalKey>::encode(const TerminalKey& value) {
    switch (value) {
        case TerminalKey::unidentified: return Json(std::string("unidentified"));
        case TerminalKey::backquote: return Json(std::string("backquote"));
        case TerminalKey::backslash: return Json(std::string("backslash"));
        case TerminalKey::bracket_left: return Json(std::string("bracket-left"));
        case TerminalKey::bracket_right: return Json(std::string("bracket-right"));
        case TerminalKey::comma: return Json(std::string("comma"));
        case TerminalKey::digit0: return Json(std::string("digit0"));
        case TerminalKey::digit1: return Json(std::string("digit1"));
        case TerminalKey::digit2: return Json(std::string("digit2"));
        case TerminalKey::digit3: return Json(std::string("digit3"));
        case TerminalKey::digit4: return Json(std::string("digit4"));
        case TerminalKey::digit5: return Json(std::string("digit5"));
        case TerminalKey::digit6: return Json(std::string("digit6"));
        case TerminalKey::digit7: return Json(std::string("digit7"));
        case TerminalKey::digit8: return Json(std::string("digit8"));
        case TerminalKey::digit9: return Json(std::string("digit9"));
        case TerminalKey::equal: return Json(std::string("equal"));
        case TerminalKey::a: return Json(std::string("a"));
        case TerminalKey::b: return Json(std::string("b"));
        case TerminalKey::c: return Json(std::string("c"));
        case TerminalKey::d: return Json(std::string("d"));
        case TerminalKey::e: return Json(std::string("e"));
        case TerminalKey::f: return Json(std::string("f"));
        case TerminalKey::g: return Json(std::string("g"));
        case TerminalKey::h: return Json(std::string("h"));
        case TerminalKey::i: return Json(std::string("i"));
        case TerminalKey::j: return Json(std::string("j"));
        case TerminalKey::k: return Json(std::string("k"));
        case TerminalKey::l: return Json(std::string("l"));
        case TerminalKey::m: return Json(std::string("m"));
        case TerminalKey::n: return Json(std::string("n"));
        case TerminalKey::o: return Json(std::string("o"));
        case TerminalKey::p: return Json(std::string("p"));
        case TerminalKey::q: return Json(std::string("q"));
        case TerminalKey::r: return Json(std::string("r"));
        case TerminalKey::s: return Json(std::string("s"));
        case TerminalKey::t: return Json(std::string("t"));
        case TerminalKey::u: return Json(std::string("u"));
        case TerminalKey::v: return Json(std::string("v"));
        case TerminalKey::w: return Json(std::string("w"));
        case TerminalKey::x: return Json(std::string("x"));
        case TerminalKey::y: return Json(std::string("y"));
        case TerminalKey::z: return Json(std::string("z"));
        case TerminalKey::minus: return Json(std::string("minus"));
        case TerminalKey::period: return Json(std::string("period"));
        case TerminalKey::quote: return Json(std::string("quote"));
        case TerminalKey::semicolon: return Json(std::string("semicolon"));
        case TerminalKey::slash: return Json(std::string("slash"));
        case TerminalKey::backspace: return Json(std::string("backspace"));
        case TerminalKey::enter: return Json(std::string("enter"));
        case TerminalKey::space: return Json(std::string("space"));
        case TerminalKey::tab: return Json(std::string("tab"));
        case TerminalKey::delete_: return Json(std::string("delete"));
        case TerminalKey::end: return Json(std::string("end"));
        case TerminalKey::home: return Json(std::string("home"));
        case TerminalKey::insert: return Json(std::string("insert"));
        case TerminalKey::page_down: return Json(std::string("page-down"));
        case TerminalKey::page_up: return Json(std::string("page-up"));
        case TerminalKey::arrow_down: return Json(std::string("arrow-down"));
        case TerminalKey::arrow_left: return Json(std::string("arrow-left"));
        case TerminalKey::arrow_right: return Json(std::string("arrow-right"));
        case TerminalKey::arrow_up: return Json(std::string("arrow-up"));
        case TerminalKey::numpad0: return Json(std::string("numpad0"));
        case TerminalKey::numpad1: return Json(std::string("numpad1"));
        case TerminalKey::numpad2: return Json(std::string("numpad2"));
        case TerminalKey::numpad3: return Json(std::string("numpad3"));
        case TerminalKey::numpad4: return Json(std::string("numpad4"));
        case TerminalKey::numpad5: return Json(std::string("numpad5"));
        case TerminalKey::numpad6: return Json(std::string("numpad6"));
        case TerminalKey::numpad7: return Json(std::string("numpad7"));
        case TerminalKey::numpad8: return Json(std::string("numpad8"));
        case TerminalKey::numpad9: return Json(std::string("numpad9"));
        case TerminalKey::numpad_add: return Json(std::string("numpad-add"));
        case TerminalKey::numpad_backspace: return Json(std::string("numpad-backspace"));
        case TerminalKey::numpad_comma: return Json(std::string("numpad-comma"));
        case TerminalKey::numpad_decimal: return Json(std::string("numpad-decimal"));
        case TerminalKey::numpad_divide: return Json(std::string("numpad-divide"));
        case TerminalKey::numpad_enter: return Json(std::string("numpad-enter"));
        case TerminalKey::numpad_equal: return Json(std::string("numpad-equal"));
        case TerminalKey::numpad_multiply: return Json(std::string("numpad-multiply"));
        case TerminalKey::numpad_subtract: return Json(std::string("numpad-subtract"));
        case TerminalKey::numpad_up: return Json(std::string("numpad-up"));
        case TerminalKey::numpad_down: return Json(std::string("numpad-down"));
        case TerminalKey::numpad_right: return Json(std::string("numpad-right"));
        case TerminalKey::numpad_left: return Json(std::string("numpad-left"));
        case TerminalKey::numpad_begin: return Json(std::string("numpad-begin"));
        case TerminalKey::numpad_home: return Json(std::string("numpad-home"));
        case TerminalKey::numpad_end: return Json(std::string("numpad-end"));
        case TerminalKey::numpad_insert: return Json(std::string("numpad-insert"));
        case TerminalKey::numpad_delete: return Json(std::string("numpad-delete"));
        case TerminalKey::numpad_page_up: return Json(std::string("numpad-page-up"));
        case TerminalKey::numpad_page_down: return Json(std::string("numpad-page-down"));
        case TerminalKey::escape: return Json(std::string("escape"));
        case TerminalKey::f1: return Json(std::string("f1"));
        case TerminalKey::f2: return Json(std::string("f2"));
        case TerminalKey::f3: return Json(std::string("f3"));
        case TerminalKey::f4: return Json(std::string("f4"));
        case TerminalKey::f5: return Json(std::string("f5"));
        case TerminalKey::f6: return Json(std::string("f6"));
        case TerminalKey::f7: return Json(std::string("f7"));
        case TerminalKey::f8: return Json(std::string("f8"));
        case TerminalKey::f9: return Json(std::string("f9"));
        case TerminalKey::f10: return Json(std::string("f10"));
        case TerminalKey::f11: return Json(std::string("f11"));
        case TerminalKey::f12: return Json(std::string("f12"));
        case TerminalKey::f13: return Json(std::string("f13"));
        case TerminalKey::f14: return Json(std::string("f14"));
        case TerminalKey::f15: return Json(std::string("f15"));
        case TerminalKey::f16: return Json(std::string("f16"));
        case TerminalKey::f17: return Json(std::string("f17"));
        case TerminalKey::f18: return Json(std::string("f18"));
        case TerminalKey::f19: return Json(std::string("f19"));
        case TerminalKey::f20: return Json(std::string("f20"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<TerminalKey> Codec<TerminalKey>::decode(const Json& value) {
    if (value == Json(std::string("unidentified"))) return TerminalKey::unidentified;
    if (value == Json(std::string("backquote"))) return TerminalKey::backquote;
    if (value == Json(std::string("backslash"))) return TerminalKey::backslash;
    if (value == Json(std::string("bracket-left"))) return TerminalKey::bracket_left;
    if (value == Json(std::string("bracket-right"))) return TerminalKey::bracket_right;
    if (value == Json(std::string("comma"))) return TerminalKey::comma;
    if (value == Json(std::string("digit0"))) return TerminalKey::digit0;
    if (value == Json(std::string("digit1"))) return TerminalKey::digit1;
    if (value == Json(std::string("digit2"))) return TerminalKey::digit2;
    if (value == Json(std::string("digit3"))) return TerminalKey::digit3;
    if (value == Json(std::string("digit4"))) return TerminalKey::digit4;
    if (value == Json(std::string("digit5"))) return TerminalKey::digit5;
    if (value == Json(std::string("digit6"))) return TerminalKey::digit6;
    if (value == Json(std::string("digit7"))) return TerminalKey::digit7;
    if (value == Json(std::string("digit8"))) return TerminalKey::digit8;
    if (value == Json(std::string("digit9"))) return TerminalKey::digit9;
    if (value == Json(std::string("equal"))) return TerminalKey::equal;
    if (value == Json(std::string("a"))) return TerminalKey::a;
    if (value == Json(std::string("b"))) return TerminalKey::b;
    if (value == Json(std::string("c"))) return TerminalKey::c;
    if (value == Json(std::string("d"))) return TerminalKey::d;
    if (value == Json(std::string("e"))) return TerminalKey::e;
    if (value == Json(std::string("f"))) return TerminalKey::f;
    if (value == Json(std::string("g"))) return TerminalKey::g;
    if (value == Json(std::string("h"))) return TerminalKey::h;
    if (value == Json(std::string("i"))) return TerminalKey::i;
    if (value == Json(std::string("j"))) return TerminalKey::j;
    if (value == Json(std::string("k"))) return TerminalKey::k;
    if (value == Json(std::string("l"))) return TerminalKey::l;
    if (value == Json(std::string("m"))) return TerminalKey::m;
    if (value == Json(std::string("n"))) return TerminalKey::n;
    if (value == Json(std::string("o"))) return TerminalKey::o;
    if (value == Json(std::string("p"))) return TerminalKey::p;
    if (value == Json(std::string("q"))) return TerminalKey::q;
    if (value == Json(std::string("r"))) return TerminalKey::r;
    if (value == Json(std::string("s"))) return TerminalKey::s;
    if (value == Json(std::string("t"))) return TerminalKey::t;
    if (value == Json(std::string("u"))) return TerminalKey::u;
    if (value == Json(std::string("v"))) return TerminalKey::v;
    if (value == Json(std::string("w"))) return TerminalKey::w;
    if (value == Json(std::string("x"))) return TerminalKey::x;
    if (value == Json(std::string("y"))) return TerminalKey::y;
    if (value == Json(std::string("z"))) return TerminalKey::z;
    if (value == Json(std::string("minus"))) return TerminalKey::minus;
    if (value == Json(std::string("period"))) return TerminalKey::period;
    if (value == Json(std::string("quote"))) return TerminalKey::quote;
    if (value == Json(std::string("semicolon"))) return TerminalKey::semicolon;
    if (value == Json(std::string("slash"))) return TerminalKey::slash;
    if (value == Json(std::string("backspace"))) return TerminalKey::backspace;
    if (value == Json(std::string("enter"))) return TerminalKey::enter;
    if (value == Json(std::string("space"))) return TerminalKey::space;
    if (value == Json(std::string("tab"))) return TerminalKey::tab;
    if (value == Json(std::string("delete"))) return TerminalKey::delete_;
    if (value == Json(std::string("end"))) return TerminalKey::end;
    if (value == Json(std::string("home"))) return TerminalKey::home;
    if (value == Json(std::string("insert"))) return TerminalKey::insert;
    if (value == Json(std::string("page-down"))) return TerminalKey::page_down;
    if (value == Json(std::string("page-up"))) return TerminalKey::page_up;
    if (value == Json(std::string("arrow-down"))) return TerminalKey::arrow_down;
    if (value == Json(std::string("arrow-left"))) return TerminalKey::arrow_left;
    if (value == Json(std::string("arrow-right"))) return TerminalKey::arrow_right;
    if (value == Json(std::string("arrow-up"))) return TerminalKey::arrow_up;
    if (value == Json(std::string("numpad0"))) return TerminalKey::numpad0;
    if (value == Json(std::string("numpad1"))) return TerminalKey::numpad1;
    if (value == Json(std::string("numpad2"))) return TerminalKey::numpad2;
    if (value == Json(std::string("numpad3"))) return TerminalKey::numpad3;
    if (value == Json(std::string("numpad4"))) return TerminalKey::numpad4;
    if (value == Json(std::string("numpad5"))) return TerminalKey::numpad5;
    if (value == Json(std::string("numpad6"))) return TerminalKey::numpad6;
    if (value == Json(std::string("numpad7"))) return TerminalKey::numpad7;
    if (value == Json(std::string("numpad8"))) return TerminalKey::numpad8;
    if (value == Json(std::string("numpad9"))) return TerminalKey::numpad9;
    if (value == Json(std::string("numpad-add"))) return TerminalKey::numpad_add;
    if (value == Json(std::string("numpad-backspace"))) return TerminalKey::numpad_backspace;
    if (value == Json(std::string("numpad-comma"))) return TerminalKey::numpad_comma;
    if (value == Json(std::string("numpad-decimal"))) return TerminalKey::numpad_decimal;
    if (value == Json(std::string("numpad-divide"))) return TerminalKey::numpad_divide;
    if (value == Json(std::string("numpad-enter"))) return TerminalKey::numpad_enter;
    if (value == Json(std::string("numpad-equal"))) return TerminalKey::numpad_equal;
    if (value == Json(std::string("numpad-multiply"))) return TerminalKey::numpad_multiply;
    if (value == Json(std::string("numpad-subtract"))) return TerminalKey::numpad_subtract;
    if (value == Json(std::string("numpad-up"))) return TerminalKey::numpad_up;
    if (value == Json(std::string("numpad-down"))) return TerminalKey::numpad_down;
    if (value == Json(std::string("numpad-right"))) return TerminalKey::numpad_right;
    if (value == Json(std::string("numpad-left"))) return TerminalKey::numpad_left;
    if (value == Json(std::string("numpad-begin"))) return TerminalKey::numpad_begin;
    if (value == Json(std::string("numpad-home"))) return TerminalKey::numpad_home;
    if (value == Json(std::string("numpad-end"))) return TerminalKey::numpad_end;
    if (value == Json(std::string("numpad-insert"))) return TerminalKey::numpad_insert;
    if (value == Json(std::string("numpad-delete"))) return TerminalKey::numpad_delete;
    if (value == Json(std::string("numpad-page-up"))) return TerminalKey::numpad_page_up;
    if (value == Json(std::string("numpad-page-down"))) return TerminalKey::numpad_page_down;
    if (value == Json(std::string("escape"))) return TerminalKey::escape;
    if (value == Json(std::string("f1"))) return TerminalKey::f1;
    if (value == Json(std::string("f2"))) return TerminalKey::f2;
    if (value == Json(std::string("f3"))) return TerminalKey::f3;
    if (value == Json(std::string("f4"))) return TerminalKey::f4;
    if (value == Json(std::string("f5"))) return TerminalKey::f5;
    if (value == Json(std::string("f6"))) return TerminalKey::f6;
    if (value == Json(std::string("f7"))) return TerminalKey::f7;
    if (value == Json(std::string("f8"))) return TerminalKey::f8;
    if (value == Json(std::string("f9"))) return TerminalKey::f9;
    if (value == Json(std::string("f10"))) return TerminalKey::f10;
    if (value == Json(std::string("f11"))) return TerminalKey::f11;
    if (value == Json(std::string("f12"))) return TerminalKey::f12;
    if (value == Json(std::string("f13"))) return TerminalKey::f13;
    if (value == Json(std::string("f14"))) return TerminalKey::f14;
    if (value == Json(std::string("f15"))) return TerminalKey::f15;
    if (value == Json(std::string("f16"))) return TerminalKey::f16;
    if (value == Json(std::string("f17"))) return TerminalKey::f17;
    if (value == Json(std::string("f18"))) return TerminalKey::f18;
    if (value == Json(std::string("f19"))) return TerminalKey::f19;
    if (value == Json(std::string("f20"))) return TerminalKey::f20;
    return make_error(ErrorCode::decode, "unknown TerminalKey value");
}

Result<Json> Codec<TerminalKeyAction>::encode(const TerminalKeyAction& value) {
    switch (value) {
        case TerminalKeyAction::press: return Json(std::string("press"));
        case TerminalKeyAction::release: return Json(std::string("release"));
        case TerminalKeyAction::repeat: return Json(std::string("repeat"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<TerminalKeyAction> Codec<TerminalKeyAction>::decode(const Json& value) {
    if (value == Json(std::string("press"))) return TerminalKeyAction::press;
    if (value == Json(std::string("release"))) return TerminalKeyAction::release;
    if (value == Json(std::string("repeat"))) return TerminalKeyAction::repeat;
    return make_error(ErrorCode::decode, "unknown TerminalKeyAction value");
}

Result<Json> Codec<TerminalKeyInput>::encode(const TerminalKeyInput& value) {
    (void)value;
    Json::Object object;
    if (!value.action.is_absent()) {
        auto encoded = encode_value(value.action);
        if (!encoded) return std::move(encoded).error();
        object.emplace("action", std::move(encoded).value());
    }
    if (!value.base_layout_codepoint.is_absent()) {
        auto encoded = encode_value(value.base_layout_codepoint);
        if (!encoded) return std::move(encoded).error();
        object.emplace("base_layout_codepoint", std::move(encoded).value());
    }
    if (value.composing) {
        auto encoded = encode_value(*value.composing);
        if (!encoded) return std::move(encoded).error();
        object.emplace("composing", std::move(encoded).value());
    }
    auto encoded_consumed_mods = encode_value(value.consumed_mods);
    if (!encoded_consumed_mods) return std::move(encoded_consumed_mods).error();
    object.emplace("consumed_mods", std::move(encoded_consumed_mods).value());
    auto encoded_key = encode_value(value.key);
    if (!encoded_key) return std::move(encoded_key).error();
    object.emplace("key", std::move(encoded_key).value());
    auto encoded_macos_option_as_alt = encode_value(value.macos_option_as_alt);
    if (!encoded_macos_option_as_alt) return std::move(encoded_macos_option_as_alt).error();
    object.emplace("macos_option_as_alt", std::move(encoded_macos_option_as_alt).value());
    auto encoded_mods = encode_value(value.mods);
    if (!encoded_mods) return std::move(encoded_mods).error();
    object.emplace("mods", std::move(encoded_mods).value());
    if (!value.shifted_codepoint.is_absent()) {
        auto encoded = encode_value(value.shifted_codepoint);
        if (!encoded) return std::move(encoded).error();
        object.emplace("shifted_codepoint", std::move(encoded).value());
    }
    if (!value.unshifted_codepoint.is_absent()) {
        auto encoded = encode_value(value.unshifted_codepoint);
        if (!encoded) return std::move(encoded).error();
        object.emplace("unshifted_codepoint", std::move(encoded).value());
    }
    auto encoded_utf8 = encode_value(value.utf8);
    if (!encoded_utf8) return std::move(encoded_utf8).error();
    object.emplace("utf8", std::move(encoded_utf8).value());
    return Json(std::move(object));
}

Result<TerminalKeyInput> Codec<TerminalKeyInput>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TerminalKeyInput result{};
    const Json* field_action = value.find("action");
    if (field_action) {
        if (field_action->is_null()) {
            result.action = Field<TerminalKeyAction>::null();
        } else {
            auto decoded = decode_value<TerminalKeyAction>(*field_action);
            if (!decoded) return std::move(decoded).error();
            result.action = Field<TerminalKeyAction>(std::move(decoded).value());
        }
    }
    const Json* field_base_layout_codepoint = value.find("base_layout_codepoint");
    if (field_base_layout_codepoint) {
        if (field_base_layout_codepoint->is_null()) {
            result.base_layout_codepoint = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_base_layout_codepoint);
            if (!decoded) return std::move(decoded).error();
            result.base_layout_codepoint = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_composing = value.find("composing");
    if (field_composing) {
        auto decoded = decode_value<bool>(*field_composing);
        if (!decoded) return std::move(decoded).error();
        result.composing = std::move(decoded).value();
    }
    const Json* field_consumed_mods = value.find("consumed_mods");
    if (!field_consumed_mods) {
        return make_error(ErrorCode::decode, "missing required field 'consumed_mods'");
    }
    if (field_consumed_mods) {
        auto decoded = decode_value<TerminalModifiers>(*field_consumed_mods);
        if (!decoded) return std::move(decoded).error();
        result.consumed_mods = std::move(decoded).value();
    }
    const Json* field_key = value.find("key");
    if (!field_key) {
        return make_error(ErrorCode::decode, "missing required field 'key'");
    }
    if (field_key) {
        auto decoded = decode_value<TerminalKey>(*field_key);
        if (!decoded) return std::move(decoded).error();
        result.key = std::move(decoded).value();
    }
    const Json* field_macos_option_as_alt = value.find("macos_option_as_alt");
    if (!field_macos_option_as_alt) {
        return make_error(ErrorCode::decode, "missing required field 'macos_option_as_alt'");
    }
    if (field_macos_option_as_alt) {
        auto decoded = decode_value<bool>(*field_macos_option_as_alt);
        if (!decoded) return std::move(decoded).error();
        result.macos_option_as_alt = std::move(decoded).value();
    }
    const Json* field_mods = value.find("mods");
    if (!field_mods) {
        return make_error(ErrorCode::decode, "missing required field 'mods'");
    }
    if (field_mods) {
        auto decoded = decode_value<TerminalModifiers>(*field_mods);
        if (!decoded) return std::move(decoded).error();
        result.mods = std::move(decoded).value();
    }
    const Json* field_shifted_codepoint = value.find("shifted_codepoint");
    if (field_shifted_codepoint) {
        if (field_shifted_codepoint->is_null()) {
            result.shifted_codepoint = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_shifted_codepoint);
            if (!decoded) return std::move(decoded).error();
            result.shifted_codepoint = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_unshifted_codepoint = value.find("unshifted_codepoint");
    if (field_unshifted_codepoint) {
        if (field_unshifted_codepoint->is_null()) {
            result.unshifted_codepoint = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_unshifted_codepoint);
            if (!decoded) return std::move(decoded).error();
            result.unshifted_codepoint = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_utf8 = value.find("utf8");
    if (!field_utf8) {
        return make_error(ErrorCode::decode, "missing required field 'utf8'");
    }
    if (field_utf8) {
        auto decoded = decode_value<std::string>(*field_utf8);
        if (!decoded) return std::move(decoded).error();
        result.utf8 = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<TerminalLifecycle>::encode(const TerminalLifecycle& value) {
    switch (value) {
        case TerminalLifecycle::launching: return Json(std::string("launching"));
        case TerminalLifecycle::adopting: return Json(std::string("adopting"));
        case TerminalLifecycle::running: return Json(std::string("running"));
        case TerminalLifecycle::exited: return Json(std::string("exited"));
        case TerminalLifecycle::tombstoned: return Json(std::string("tombstoned"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<TerminalLifecycle> Codec<TerminalLifecycle>::decode(const Json& value) {
    if (value == Json(std::string("launching"))) return TerminalLifecycle::launching;
    if (value == Json(std::string("adopting"))) return TerminalLifecycle::adopting;
    if (value == Json(std::string("running"))) return TerminalLifecycle::running;
    if (value == Json(std::string("exited"))) return TerminalLifecycle::exited;
    if (value == Json(std::string("tombstoned"))) return TerminalLifecycle::tombstoned;
    return make_error(ErrorCode::decode, "unknown TerminalLifecycle value");
}

Result<Json> Codec<TerminalModifiers>::encode(const TerminalModifiers& value) {
    (void)value;
    Json::Object object;
    auto encoded_alt = encode_value(value.alt);
    if (!encoded_alt) return std::move(encoded_alt).error();
    object.emplace("alt", std::move(encoded_alt).value());
    auto encoded_caps_lock = encode_value(value.caps_lock);
    if (!encoded_caps_lock) return std::move(encoded_caps_lock).error();
    object.emplace("caps_lock", std::move(encoded_caps_lock).value());
    auto encoded_control = encode_value(value.control);
    if (!encoded_control) return std::move(encoded_control).error();
    object.emplace("control", std::move(encoded_control).value());
    auto encoded_num_lock = encode_value(value.num_lock);
    if (!encoded_num_lock) return std::move(encoded_num_lock).error();
    object.emplace("num_lock", std::move(encoded_num_lock).value());
    auto encoded_shift = encode_value(value.shift);
    if (!encoded_shift) return std::move(encoded_shift).error();
    object.emplace("shift", std::move(encoded_shift).value());
    auto encoded_super = encode_value(value.super);
    if (!encoded_super) return std::move(encoded_super).error();
    object.emplace("super", std::move(encoded_super).value());
    return Json(std::move(object));
}

Result<TerminalModifiers> Codec<TerminalModifiers>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TerminalModifiers result{};
    const Json* field_alt = value.find("alt");
    if (!field_alt) {
        return make_error(ErrorCode::decode, "missing required field 'alt'");
    }
    if (field_alt) {
        auto decoded = decode_value<bool>(*field_alt);
        if (!decoded) return std::move(decoded).error();
        result.alt = std::move(decoded).value();
    }
    const Json* field_caps_lock = value.find("caps_lock");
    if (!field_caps_lock) {
        return make_error(ErrorCode::decode, "missing required field 'caps_lock'");
    }
    if (field_caps_lock) {
        auto decoded = decode_value<bool>(*field_caps_lock);
        if (!decoded) return std::move(decoded).error();
        result.caps_lock = std::move(decoded).value();
    }
    const Json* field_control = value.find("control");
    if (!field_control) {
        return make_error(ErrorCode::decode, "missing required field 'control'");
    }
    if (field_control) {
        auto decoded = decode_value<bool>(*field_control);
        if (!decoded) return std::move(decoded).error();
        result.control = std::move(decoded).value();
    }
    const Json* field_num_lock = value.find("num_lock");
    if (!field_num_lock) {
        return make_error(ErrorCode::decode, "missing required field 'num_lock'");
    }
    if (field_num_lock) {
        auto decoded = decode_value<bool>(*field_num_lock);
        if (!decoded) return std::move(decoded).error();
        result.num_lock = std::move(decoded).value();
    }
    const Json* field_shift = value.find("shift");
    if (!field_shift) {
        return make_error(ErrorCode::decode, "missing required field 'shift'");
    }
    if (field_shift) {
        auto decoded = decode_value<bool>(*field_shift);
        if (!decoded) return std::move(decoded).error();
        result.shift = std::move(decoded).value();
    }
    const Json* field_super = value.find("super");
    if (!field_super) {
        return make_error(ErrorCode::decode, "missing required field 'super'");
    }
    if (field_super) {
        auto decoded = decode_value<bool>(*field_super);
        if (!decoded) return std::move(decoded).error();
        result.super = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<TerminalPlacement>::encode(const TerminalPlacement& value) {
    (void)value;
    Json::Object object;
    auto encoded_already_exited = encode_value(value.already_exited);
    if (!encoded_already_exited) return std::move(encoded_already_exited).error();
    object.emplace("already_exited", std::move(encoded_already_exited).value());
    if (value.exit) {
        auto encoded = encode_value(*value.exit);
        if (!encoded) return std::move(encoded).error();
        object.emplace("exit", std::move(encoded).value());
    } else {
        object.emplace("exit", Json(nullptr));
    }
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    auto encoded_key = encode_value(value.key);
    if (!encoded_key) return std::move(encoded_key).error();
    object.emplace("key", std::move(encoded_key).value());
    auto encoded_lifecycle = encode_value(value.lifecycle);
    if (!encoded_lifecycle) return std::move(encoded_lifecycle).error();
    object.emplace("lifecycle", std::move(encoded_lifecycle).value());
    if (value.pane) {
        auto encoded = encode_value(*value.pane);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pane", std::move(encoded).value());
    } else {
        object.emplace("pane", Json(nullptr));
    }
    auto encoded_registry_id = encode_value(value.registry_id);
    if (!encoded_registry_id) return std::move(encoded_registry_id).error();
    object.emplace("registry_id", std::move(encoded_registry_id).value());
    auto encoded_replayed = encode_value(value.replayed);
    if (!encoded_replayed) return std::move(encoded_replayed).error();
    object.emplace("replayed", std::move(encoded_replayed).value());
    if (value.screen) {
        auto encoded = encode_value(*value.screen);
        if (!encoded) return std::move(encoded).error();
        object.emplace("screen", std::move(encoded).value());
    } else {
        object.emplace("screen", Json(nullptr));
    }
    if (value.surface) {
        auto encoded = encode_value(*value.surface);
        if (!encoded) return std::move(encoded).error();
        object.emplace("surface", std::move(encoded).value());
    } else {
        object.emplace("surface", Json(nullptr));
    }
    auto encoded_terminal_id = encode_value(value.terminal_id);
    if (!encoded_terminal_id) return std::move(encoded_terminal_id).error();
    object.emplace("terminal_id", std::move(encoded_terminal_id).value());
    if (value.terminal_incarnation) {
        auto encoded = encode_value(*value.terminal_incarnation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal_incarnation", std::move(encoded).value());
    } else {
        object.emplace("terminal_incarnation", Json(nullptr));
    }
    auto encoded_terminal_revision = encode_value(value.terminal_revision);
    if (!encoded_terminal_revision) return std::move(encoded_terminal_revision).error();
    object.emplace("terminal_revision", std::move(encoded_terminal_revision).value());
    if (value.workspace) {
        auto encoded = encode_value(*value.workspace);
        if (!encoded) return std::move(encoded).error();
        object.emplace("workspace", std::move(encoded).value());
    } else {
        object.emplace("workspace", Json(nullptr));
    }
    return Json(std::move(object));
}

Result<TerminalPlacement> Codec<TerminalPlacement>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TerminalPlacement result{};
    const Json* field_already_exited = value.find("already_exited");
    if (!field_already_exited) {
        return make_error(ErrorCode::decode, "missing required field 'already_exited'");
    }
    if (field_already_exited) {
        auto decoded = decode_value<bool>(*field_already_exited);
        if (!decoded) return std::move(decoded).error();
        result.already_exited = std::move(decoded).value();
    }
    const Json* field_exit = value.find("exit");
    if (!field_exit) {
        return make_error(ErrorCode::decode, "missing required field 'exit'");
    }
    if (field_exit) {
        if (field_exit->is_null()) {
            result.exit.reset();
        } else {
            auto decoded = decode_value<TerminalExit>(*field_exit);
            if (!decoded) return std::move(decoded).error();
            result.exit = std::move(decoded).value();
        }
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_key = value.find("key");
    if (!field_key) {
        return make_error(ErrorCode::decode, "missing required field 'key'");
    }
    if (field_key) {
        auto decoded = decode_value<std::string>(*field_key);
        if (!decoded) return std::move(decoded).error();
        result.key = std::move(decoded).value();
    }
    const Json* field_lifecycle = value.find("lifecycle");
    if (!field_lifecycle) {
        return make_error(ErrorCode::decode, "missing required field 'lifecycle'");
    }
    if (field_lifecycle) {
        auto decoded = decode_value<TerminalLifecycle>(*field_lifecycle);
        if (!decoded) return std::move(decoded).error();
        result.lifecycle = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        if (field_pane->is_null()) {
            result.pane.reset();
        } else {
            auto decoded = decode_value<Id>(*field_pane);
            if (!decoded) return std::move(decoded).error();
            result.pane = std::move(decoded).value();
        }
    }
    const Json* field_registry_id = value.find("registry_id");
    if (!field_registry_id) {
        return make_error(ErrorCode::decode, "missing required field 'registry_id'");
    }
    if (field_registry_id) {
        auto decoded = decode_value<std::string>(*field_registry_id);
        if (!decoded) return std::move(decoded).error();
        result.registry_id = std::move(decoded).value();
    }
    const Json* field_replayed = value.find("replayed");
    if (!field_replayed) {
        return make_error(ErrorCode::decode, "missing required field 'replayed'");
    }
    if (field_replayed) {
        auto decoded = decode_value<bool>(*field_replayed);
        if (!decoded) return std::move(decoded).error();
        result.replayed = std::move(decoded).value();
    }
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        if (field_screen->is_null()) {
            result.screen.reset();
        } else {
            auto decoded = decode_value<Id>(*field_screen);
            if (!decoded) return std::move(decoded).error();
            result.screen = std::move(decoded).value();
        }
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        if (field_surface->is_null()) {
            result.surface.reset();
        } else {
            auto decoded = decode_value<Id>(*field_surface);
            if (!decoded) return std::move(decoded).error();
            result.surface = std::move(decoded).value();
        }
    }
    const Json* field_terminal_id = value.find("terminal_id");
    if (!field_terminal_id) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_id'");
    }
    if (field_terminal_id) {
        auto decoded = decode_value<std::string>(*field_terminal_id);
        if (!decoded) return std::move(decoded).error();
        result.terminal_id = std::move(decoded).value();
    }
    const Json* field_terminal_incarnation = value.find("terminal_incarnation");
    if (!field_terminal_incarnation) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_incarnation'");
    }
    if (field_terminal_incarnation) {
        if (field_terminal_incarnation->is_null()) {
            result.terminal_incarnation.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_terminal_incarnation);
            if (!decoded) return std::move(decoded).error();
            result.terminal_incarnation = std::move(decoded).value();
        }
    }
    const Json* field_terminal_revision = value.find("terminal_revision");
    if (!field_terminal_revision) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_revision'");
    }
    if (field_terminal_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_terminal_revision);
        if (!decoded) return std::move(decoded).error();
        result.terminal_revision = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        if (field_workspace->is_null()) {
            result.workspace.reset();
        } else {
            auto decoded = decode_value<Id>(*field_workspace);
            if (!decoded) return std::move(decoded).error();
            result.workspace = std::move(decoded).value();
        }
    }
    return result;
}

Result<Json> Codec<TerminalRecord>::encode(const TerminalRecord& value) {
    (void)value;
    Json::Object object;
    if (value.exit) {
        auto encoded = encode_value(*value.exit);
        if (!encoded) return std::move(encoded).error();
        object.emplace("exit", std::move(encoded).value());
    } else {
        object.emplace("exit", Json(nullptr));
    }
    auto encoded_launch_spec = encode_value(value.launch_spec);
    if (!encoded_launch_spec) return std::move(encoded_launch_spec).error();
    object.emplace("launch_spec", std::move(encoded_launch_spec).value());
    auto encoded_lifecycle = encode_value(value.lifecycle);
    if (!encoded_lifecycle) return std::move(encoded_lifecycle).error();
    object.emplace("lifecycle", std::move(encoded_lifecycle).value());
    auto encoded_terminal_id = encode_value(value.terminal_id);
    if (!encoded_terminal_id) return std::move(encoded_terminal_id).error();
    object.emplace("terminal_id", std::move(encoded_terminal_id).value());
    if (value.terminal_incarnation) {
        auto encoded = encode_value(*value.terminal_incarnation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal_incarnation", std::move(encoded).value());
    } else {
        object.emplace("terminal_incarnation", Json(nullptr));
    }
    auto encoded_workspace_key = encode_value(value.workspace_key);
    if (!encoded_workspace_key) return std::move(encoded_workspace_key).error();
    object.emplace("workspace_key", std::move(encoded_workspace_key).value());
    return Json(std::move(object));
}

Result<TerminalRecord> Codec<TerminalRecord>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TerminalRecord result{};
    const Json* field_exit = value.find("exit");
    if (!field_exit) {
        return make_error(ErrorCode::decode, "missing required field 'exit'");
    }
    if (field_exit) {
        if (field_exit->is_null()) {
            result.exit.reset();
        } else {
            auto decoded = decode_value<TerminalExit>(*field_exit);
            if (!decoded) return std::move(decoded).error();
            result.exit = std::move(decoded).value();
        }
    }
    const Json* field_launch_spec = value.find("launch_spec");
    if (!field_launch_spec) {
        return make_error(ErrorCode::decode, "missing required field 'launch_spec'");
    }
    if (field_launch_spec) {
        auto decoded = decode_value<JsonValue>(*field_launch_spec);
        if (!decoded) return std::move(decoded).error();
        result.launch_spec = std::move(decoded).value();
    }
    const Json* field_lifecycle = value.find("lifecycle");
    if (!field_lifecycle) {
        return make_error(ErrorCode::decode, "missing required field 'lifecycle'");
    }
    if (field_lifecycle) {
        auto decoded = decode_value<TerminalLifecycle>(*field_lifecycle);
        if (!decoded) return std::move(decoded).error();
        result.lifecycle = std::move(decoded).value();
    }
    const Json* field_terminal_id = value.find("terminal_id");
    if (!field_terminal_id) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_id'");
    }
    if (field_terminal_id) {
        auto decoded = decode_value<std::string>(*field_terminal_id);
        if (!decoded) return std::move(decoded).error();
        result.terminal_id = std::move(decoded).value();
    }
    const Json* field_terminal_incarnation = value.find("terminal_incarnation");
    if (!field_terminal_incarnation) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_incarnation'");
    }
    if (field_terminal_incarnation) {
        if (field_terminal_incarnation->is_null()) {
            result.terminal_incarnation.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_terminal_incarnation);
            if (!decoded) return std::move(decoded).error();
            result.terminal_incarnation = std::move(decoded).value();
        }
    }
    const Json* field_workspace_key = value.find("workspace_key");
    if (!field_workspace_key) {
        return make_error(ErrorCode::decode, "missing required field 'workspace_key'");
    }
    if (field_workspace_key) {
        auto decoded = decode_value<std::string>(*field_workspace_key);
        if (!decoded) return std::move(decoded).error();
        result.workspace_key = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<TerminalRegistryEvent>::encode(const TerminalRegistryEvent& value) {
    (void)value;
    Json::Object object;
    auto encoded_kind = encode_value(value.kind);
    if (!encoded_kind) return std::move(encoded_kind).error();
    object.emplace("kind", std::move(encoded_kind).value());
    auto encoded_mutation_id = encode_value(value.mutation_id);
    if (!encoded_mutation_id) return std::move(encoded_mutation_id).error();
    object.emplace("mutation_id", std::move(encoded_mutation_id).value());
    auto encoded_origin = encode_value(value.origin);
    if (!encoded_origin) return std::move(encoded_origin).error();
    object.emplace("origin", std::move(encoded_origin).value());
    auto encoded_result = encode_value(value.result);
    if (!encoded_result) return std::move(encoded_result).error();
    object.emplace("result", std::move(encoded_result).value());
    auto encoded_terminal_id = encode_value(value.terminal_id);
    if (!encoded_terminal_id) return std::move(encoded_terminal_id).error();
    object.emplace("terminal_id", std::move(encoded_terminal_id).value());
    auto encoded_terminal_revision = encode_value(value.terminal_revision);
    if (!encoded_terminal_revision) return std::move(encoded_terminal_revision).error();
    object.emplace("terminal_revision", std::move(encoded_terminal_revision).value());
    auto encoded_workspace_key = encode_value(value.workspace_key);
    if (!encoded_workspace_key) return std::move(encoded_workspace_key).error();
    object.emplace("workspace_key", std::move(encoded_workspace_key).value());
    return Json(std::move(object));
}

Result<TerminalRegistryEvent> Codec<TerminalRegistryEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TerminalRegistryEvent result{};
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        auto decoded = decode_value<std::string>(*field_kind);
        if (!decoded) return std::move(decoded).error();
        result.kind = std::move(decoded).value();
    }
    const Json* field_mutation_id = value.find("mutation_id");
    if (!field_mutation_id) {
        return make_error(ErrorCode::decode, "missing required field 'mutation_id'");
    }
    if (field_mutation_id) {
        auto decoded = decode_value<std::string>(*field_mutation_id);
        if (!decoded) return std::move(decoded).error();
        result.mutation_id = std::move(decoded).value();
    }
    const Json* field_origin = value.find("origin");
    if (!field_origin) {
        return make_error(ErrorCode::decode, "missing required field 'origin'");
    }
    if (field_origin) {
        auto decoded = decode_value<std::string>(*field_origin);
        if (!decoded) return std::move(decoded).error();
        result.origin = std::move(decoded).value();
    }
    const Json* field_result = value.find("result");
    if (!field_result) {
        return make_error(ErrorCode::decode, "missing required field 'result'");
    }
    if (field_result) {
        auto decoded = decode_value<JsonValue>(*field_result);
        if (!decoded) return std::move(decoded).error();
        result.result = std::move(decoded).value();
    }
    const Json* field_terminal_id = value.find("terminal_id");
    if (!field_terminal_id) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_id'");
    }
    if (field_terminal_id) {
        auto decoded = decode_value<std::string>(*field_terminal_id);
        if (!decoded) return std::move(decoded).error();
        result.terminal_id = std::move(decoded).value();
    }
    const Json* field_terminal_revision = value.find("terminal_revision");
    if (!field_terminal_revision) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_revision'");
    }
    if (field_terminal_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_terminal_revision);
        if (!decoded) return std::move(decoded).error();
        result.terminal_revision = std::move(decoded).value();
    }
    const Json* field_workspace_key = value.find("workspace_key");
    if (!field_workspace_key) {
        return make_error(ErrorCode::decode, "missing required field 'workspace_key'");
    }
    if (field_workspace_key) {
        auto decoded = decode_value<std::string>(*field_workspace_key);
        if (!decoded) return std::move(decoded).error();
        result.workspace_key = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<Tree>::encode(const Tree& value) {
    (void)value;
    Json::Object object;
    if (value.generation) {
        auto encoded = encode_value(*value.generation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("generation", std::move(encoded).value());
    }
    if (value.pane_revision) {
        auto encoded = encode_value(*value.pane_revision);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pane_revision", std::move(encoded).value());
    }
    if (value.registry_id) {
        auto encoded = encode_value(*value.registry_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("registry_id", std::move(encoded).value());
    }
    if (value.terminal_revision) {
        auto encoded = encode_value(*value.terminal_revision);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal_revision", std::move(encoded).value());
    }
    if (value.workspace_revision) {
        auto encoded = encode_value(*value.workspace_revision);
        if (!encoded) return std::move(encoded).error();
        object.emplace("workspace_revision", std::move(encoded).value());
    }
    auto encoded_workspaces = encode_value(value.workspaces);
    if (!encoded_workspaces) return std::move(encoded_workspaces).error();
    object.emplace("workspaces", std::move(encoded_workspaces).value());
    return Json(std::move(object));
}

Result<Tree> Codec<Tree>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    Tree result{};
    const Json* field_generation = value.find("generation");
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_pane_revision = value.find("pane_revision");
    if (field_pane_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_pane_revision);
        if (!decoded) return std::move(decoded).error();
        result.pane_revision = std::move(decoded).value();
    }
    const Json* field_registry_id = value.find("registry_id");
    if (field_registry_id) {
        auto decoded = decode_value<std::string>(*field_registry_id);
        if (!decoded) return std::move(decoded).error();
        result.registry_id = std::move(decoded).value();
    }
    const Json* field_terminal_revision = value.find("terminal_revision");
    if (field_terminal_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_terminal_revision);
        if (!decoded) return std::move(decoded).error();
        result.terminal_revision = std::move(decoded).value();
    }
    const Json* field_workspace_revision = value.find("workspace_revision");
    if (field_workspace_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_workspace_revision);
        if (!decoded) return std::move(decoded).error();
        result.workspace_revision = std::move(decoded).value();
    }
    const Json* field_workspaces = value.find("workspaces");
    if (!field_workspaces) {
        return make_error(ErrorCode::decode, "missing required field 'workspaces'");
    }
    if (field_workspaces) {
        auto decoded = decode_value<std::vector<Workspace>>(*field_workspaces);
        if (!decoded) return std::move(decoded).error();
        result.workspaces = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ViewAttachmentOutcome>::encode(const ViewAttachmentOutcome& value) {
    switch (value) {
        case ViewAttachmentOutcome::applied: return Json(std::string("applied"));
        case ViewAttachmentOutcome::passive: return Json(std::string("passive"));
        case ViewAttachmentOutcome::superseded: return Json(std::string("superseded"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<ViewAttachmentOutcome> Codec<ViewAttachmentOutcome>::decode(const Json& value) {
    if (value == Json(std::string("applied"))) return ViewAttachmentOutcome::applied;
    if (value == Json(std::string("passive"))) return ViewAttachmentOutcome::passive;
    if (value == Json(std::string("superseded"))) return ViewAttachmentOutcome::superseded;
    return make_error(ErrorCode::decode, "unknown ViewAttachmentOutcome value");
}

Result<Json> Codec<VtStateResult>::encode(const VtStateResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_cols = encode_value(value.cols);
    if (!encoded_cols) return std::move(encoded_cols).error();
    object.emplace("cols", std::move(encoded_cols).value());
    auto encoded_data = encode_value(value.data);
    if (!encoded_data) return std::move(encoded_data).error();
    object.emplace("data", std::move(encoded_data).value());
    if (value.kitty_graphics_state) {
        auto encoded = encode_value(*value.kitty_graphics_state);
        if (!encoded) return std::move(encoded).error();
        object.emplace("kitty_graphics_state", std::move(encoded).value());
    }
    if (value.kitty_image_aliases) {
        auto encoded = encode_value(*value.kitty_image_aliases);
        if (!encoded) return std::move(encoded).error();
        object.emplace("kitty_image_aliases", std::move(encoded).value());
    }
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    return Json(std::move(object));
}

Result<VtStateResult> Codec<VtStateResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    VtStateResult result{};
    const Json* field_cols = value.find("cols");
    if (!field_cols) {
        return make_error(ErrorCode::decode, "missing required field 'cols'");
    }
    if (field_cols) {
        auto decoded = decode_value<std::uint16_t>(*field_cols);
        if (!decoded) return std::move(decoded).error();
        result.cols = std::move(decoded).value();
    }
    const Json* field_data = value.find("data");
    if (!field_data) {
        return make_error(ErrorCode::decode, "missing required field 'data'");
    }
    if (field_data) {
        auto decoded = decode_value<Base64>(*field_data);
        if (!decoded) return std::move(decoded).error();
        result.data = std::move(decoded).value();
    }
    const Json* field_kitty_graphics_state = value.find("kitty_graphics_state");
    if (field_kitty_graphics_state) {
        auto decoded = decode_value<KittyGraphicsState>(*field_kitty_graphics_state);
        if (!decoded) return std::move(decoded).error();
        result.kitty_graphics_state = std::move(decoded).value();
    }
    const Json* field_kitty_image_aliases = value.find("kitty_image_aliases");
    if (field_kitty_image_aliases) {
        auto decoded = decode_value<std::vector<KittyImageAlias>>(*field_kitty_image_aliases);
        if (!decoded) return std::move(decoded).error();
        result.kitty_image_aliases = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::uint16_t>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<WaitForResult>::encode(const WaitForResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_elapsed_ms = encode_value(value.elapsed_ms);
    if (!encoded_elapsed_ms) return std::move(encoded_elapsed_ms).error();
    object.emplace("elapsed_ms", std::move(encoded_elapsed_ms).value());
    object.emplace("matched", Json(true));
    auto encoded_text = encode_value(value.text);
    if (!encoded_text) return std::move(encoded_text).error();
    object.emplace("text", std::move(encoded_text).value());
    return Json(std::move(object));
}

Result<WaitForResult> Codec<WaitForResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    WaitForResult result{};
    const Json* field_elapsed_ms = value.find("elapsed_ms");
    if (!field_elapsed_ms) {
        return make_error(ErrorCode::decode, "missing required field 'elapsed_ms'");
    }
    if (field_elapsed_ms) {
        auto decoded = decode_value<std::uint64_t>(*field_elapsed_ms);
        if (!decoded) return std::move(decoded).error();
        result.elapsed_ms = std::move(decoded).value();
    }
    const Json* field_matched = value.find("matched");
    if (!field_matched) {
        return make_error(ErrorCode::decode, "missing required field 'matched'");
    }
    if (field_matched) {
        if (*field_matched != Json(true)) {
            return make_error(ErrorCode::decode, "field 'matched' has the wrong literal value");
        }
    }
    const Json* field_text = value.find("text");
    if (!field_text) {
        return make_error(ErrorCode::decode, "missing required field 'text'");
    }
    if (field_text) {
        auto decoded = decode_value<std::string>(*field_text);
        if (!decoded) return std::move(decoded).error();
        result.text = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<Workspace>::encode(const Workspace& value) {
    (void)value;
    Json::Object object;
    auto encoded_active = encode_value(value.active);
    if (!encoded_active) return std::move(encoded_active).error();
    object.emplace("active", std::move(encoded_active).value());
    auto encoded_id = encode_value(value.id);
    if (!encoded_id) return std::move(encoded_id).error();
    object.emplace("id", std::move(encoded_id).value());
    if (value.key) {
        auto encoded = encode_value(*value.key);
        if (!encoded) return std::move(encoded).error();
        object.emplace("key", std::move(encoded).value());
    }
    auto encoded_name = encode_value(value.name);
    if (!encoded_name) return std::move(encoded_name).error();
    object.emplace("name", std::move(encoded_name).value());
    auto encoded_screens = encode_value(value.screens);
    if (!encoded_screens) return std::move(encoded_screens).error();
    object.emplace("screens", std::move(encoded_screens).value());
    if (value.short_id) {
        auto encoded = encode_value(*value.short_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("short_id", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<Workspace> Codec<Workspace>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    Workspace result{};
    const Json* field_active = value.find("active");
    if (!field_active) {
        return make_error(ErrorCode::decode, "missing required field 'active'");
    }
    if (field_active) {
        auto decoded = decode_value<bool>(*field_active);
        if (!decoded) return std::move(decoded).error();
        result.active = std::move(decoded).value();
    }
    const Json* field_id = value.find("id");
    if (!field_id) {
        return make_error(ErrorCode::decode, "missing required field 'id'");
    }
    if (field_id) {
        auto decoded = decode_value<Id>(*field_id);
        if (!decoded) return std::move(decoded).error();
        result.id = std::move(decoded).value();
    }
    const Json* field_key = value.find("key");
    if (field_key) {
        auto decoded = decode_value<std::string>(*field_key);
        if (!decoded) return std::move(decoded).error();
        result.key = std::move(decoded).value();
    }
    const Json* field_name = value.find("name");
    if (!field_name) {
        return make_error(ErrorCode::decode, "missing required field 'name'");
    }
    if (field_name) {
        auto decoded = decode_value<std::string>(*field_name);
        if (!decoded) return std::move(decoded).error();
        result.name = std::move(decoded).value();
    }
    const Json* field_screens = value.find("screens");
    if (!field_screens) {
        return make_error(ErrorCode::decode, "missing required field 'screens'");
    }
    if (field_screens) {
        auto decoded = decode_value<std::vector<Screen>>(*field_screens);
        if (!decoded) return std::move(decoded).error();
        result.screens = std::move(decoded).value();
    }
    const Json* field_short_id = value.find("short_id");
    if (field_short_id) {
        auto decoded = decode_value<std::string>(*field_short_id);
        if (!decoded) return std::move(decoded).error();
        result.short_id = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<WorkspaceMutationResult>::encode(const WorkspaceMutationResult& value) {
    (void)value;
    Json::Object object;
    if (value.changed) {
        auto encoded = encode_value(*value.changed);
        if (!encoded) return std::move(encoded).error();
        object.emplace("changed", std::move(encoded).value());
    }
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    auto encoded_index = encode_value(value.index);
    if (!encoded_index) return std::move(encoded_index).error();
    object.emplace("index", std::move(encoded_index).value());
    auto encoded_key = encode_value(value.key);
    if (!encoded_key) return std::move(encoded_key).error();
    object.emplace("key", std::move(encoded_key).value());
    auto encoded_registry_id = encode_value(value.registry_id);
    if (!encoded_registry_id) return std::move(encoded_registry_id).error();
    object.emplace("registry_id", std::move(encoded_registry_id).value());
    auto encoded_replayed = encode_value(value.replayed);
    if (!encoded_replayed) return std::move(encoded_replayed).error();
    object.emplace("replayed", std::move(encoded_replayed).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    auto encoded_workspace_revision = encode_value(value.workspace_revision);
    if (!encoded_workspace_revision) return std::move(encoded_workspace_revision).error();
    object.emplace("workspace_revision", std::move(encoded_workspace_revision).value());
    return Json(std::move(object));
}

Result<WorkspaceMutationResult> Codec<WorkspaceMutationResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    WorkspaceMutationResult result{};
    const Json* field_changed = value.find("changed");
    if (field_changed) {
        auto decoded = decode_value<bool>(*field_changed);
        if (!decoded) return std::move(decoded).error();
        result.changed = std::move(decoded).value();
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_index = value.find("index");
    if (!field_index) {
        return make_error(ErrorCode::decode, "missing required field 'index'");
    }
    if (field_index) {
        auto decoded = decode_value<std::uint64_t>(*field_index);
        if (!decoded) return std::move(decoded).error();
        result.index = std::move(decoded).value();
    }
    const Json* field_key = value.find("key");
    if (!field_key) {
        return make_error(ErrorCode::decode, "missing required field 'key'");
    }
    if (field_key) {
        auto decoded = decode_value<std::string>(*field_key);
        if (!decoded) return std::move(decoded).error();
        result.key = std::move(decoded).value();
    }
    const Json* field_registry_id = value.find("registry_id");
    if (!field_registry_id) {
        return make_error(ErrorCode::decode, "missing required field 'registry_id'");
    }
    if (field_registry_id) {
        auto decoded = decode_value<std::string>(*field_registry_id);
        if (!decoded) return std::move(decoded).error();
        result.registry_id = std::move(decoded).value();
    }
    const Json* field_replayed = value.find("replayed");
    if (!field_replayed) {
        return make_error(ErrorCode::decode, "missing required field 'replayed'");
    }
    if (field_replayed) {
        auto decoded = decode_value<bool>(*field_replayed);
        if (!decoded) return std::move(decoded).error();
        result.replayed = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    const Json* field_workspace_revision = value.find("workspace_revision");
    if (!field_workspace_revision) {
        return make_error(ErrorCode::decode, "missing required field 'workspace_revision'");
    }
    if (field_workspace_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_workspace_revision);
        if (!decoded) return std::move(decoded).error();
        result.workspace_revision = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ZoomPaneResult>::encode(const ZoomPaneResult& value) {
    (void)value;
    Json::Object object;
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    auto encoded_zoomed = encode_value(value.zoomed);
    if (!encoded_zoomed) return std::move(encoded_zoomed).error();
    object.emplace("zoomed", std::move(encoded_zoomed).value());
    if (value.zoomed_pane) {
        auto encoded = encode_value(*value.zoomed_pane);
        if (!encoded) return std::move(encoded).error();
        object.emplace("zoomed_pane", std::move(encoded).value());
    } else {
        object.emplace("zoomed_pane", Json(nullptr));
    }
    return Json(std::move(object));
}

Result<ZoomPaneResult> Codec<ZoomPaneResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ZoomPaneResult result{};
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_zoomed = value.find("zoomed");
    if (!field_zoomed) {
        return make_error(ErrorCode::decode, "missing required field 'zoomed'");
    }
    if (field_zoomed) {
        auto decoded = decode_value<bool>(*field_zoomed);
        if (!decoded) return std::move(decoded).error();
        result.zoomed = std::move(decoded).value();
    }
    const Json* field_zoomed_pane = value.find("zoomed_pane");
    if (!field_zoomed_pane) {
        return make_error(ErrorCode::decode, "missing required field 'zoomed_pane'");
    }
    if (field_zoomed_pane) {
        if (field_zoomed_pane->is_null()) {
            result.zoomed_pane.reset();
        } else {
            auto decoded = decode_value<Id>(*field_zoomed_pane);
            if (!decoded) return std::move(decoded).error();
            result.zoomed_pane = std::move(decoded).value();
        }
    }
    return result;
}

Result<Json> Codec<ApplyLayoutRequest>::encode(const ApplyLayoutRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.cols.is_absent()) {
        auto encoded = encode_value(value.cols);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cols", std::move(encoded).value());
    }
    auto encoded_layout = encode_value(value.layout);
    if (!encoded_layout) return std::move(encoded_layout).error();
    object.emplace("layout", std::move(encoded_layout).value());
    if (!value.name.is_absent()) {
        auto encoded = encode_value(value.name);
        if (!encoded) return std::move(encoded).error();
        object.emplace("name", std::move(encoded).value());
    }
    if (!value.rows.is_absent()) {
        auto encoded = encode_value(value.rows);
        if (!encoded) return std::move(encoded).error();
        object.emplace("rows", std::move(encoded).value());
    }
    if (!value.workspace.is_absent()) {
        auto encoded = encode_value(value.workspace);
        if (!encoded) return std::move(encoded).error();
        object.emplace("workspace", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<ApplyLayoutRequest> Codec<ApplyLayoutRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ApplyLayoutRequest result{};
    const Json* field_cols = value.find("cols");
    if (field_cols) {
        if (field_cols->is_null()) {
            result.cols = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_cols);
            if (!decoded) return std::move(decoded).error();
            result.cols = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_layout = value.find("layout");
    if (!field_layout) {
        return make_error(ErrorCode::decode, "missing required field 'layout'");
    }
    if (field_layout) {
        auto decoded = decode_value<DeclarativeLayout>(*field_layout);
        if (!decoded) return std::move(decoded).error();
        result.layout = std::move(decoded).value();
    }
    const Json* field_name = value.find("name");
    if (field_name) {
        if (field_name->is_null()) {
            result.name = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_name);
            if (!decoded) return std::move(decoded).error();
            result.name = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_rows = value.find("rows");
    if (field_rows) {
        if (field_rows->is_null()) {
            result.rows = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_rows);
            if (!decoded) return std::move(decoded).error();
            result.rows = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_workspace = value.find("workspace");
    if (field_workspace) {
        if (field_workspace->is_null()) {
            result.workspace = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_workspace);
            if (!decoded) return std::move(decoded).error();
            result.workspace = Field<Id>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<AttachSurfaceRequest>::encode(const AttachSurfaceRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.cols.is_absent()) {
        auto encoded = encode_value(value.cols);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cols", std::move(encoded).value());
    }
    if (!value.mode.is_absent()) {
        auto encoded = encode_value(value.mode);
        if (!encoded) return std::move(encoded).error();
        object.emplace("mode", std::move(encoded).value());
    }
    if (!value.rows.is_absent()) {
        auto encoded = encode_value(value.rows);
        if (!encoded) return std::move(encoded).error();
        object.emplace("rows", std::move(encoded).value());
    }
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<AttachSurfaceRequest> Codec<AttachSurfaceRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    AttachSurfaceRequest result{};
    const Json* field_cols = value.find("cols");
    if (field_cols) {
        if (field_cols->is_null()) {
            result.cols = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_cols);
            if (!decoded) return std::move(decoded).error();
            result.cols = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_mode = value.find("mode");
    if (field_mode) {
        if (field_mode->is_null()) {
            result.mode = Field<AttachSurfaceRequestMode>::null();
        } else {
            auto decoded = decode_value<AttachSurfaceRequestMode>(*field_mode);
            if (!decoded) return std::move(decoded).error();
            result.mode = Field<AttachSurfaceRequestMode>(std::move(decoded).value());
        }
    }
    const Json* field_rows = value.find("rows");
    if (field_rows) {
        if (field_rows->is_null()) {
            result.rows = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_rows);
            if (!decoded) return std::move(decoded).error();
            result.rows = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserActivateRequest>::encode(const BrowserActivateRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<BrowserActivateRequest> Codec<BrowserActivateRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserActivateRequest result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserBackRequest>::encode(const BrowserBackRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<BrowserBackRequest> Codec<BrowserBackRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserBackRequest result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserForwardRequest>::encode(const BrowserForwardRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<BrowserForwardRequest> Codec<BrowserForwardRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserForwardRequest result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserFramePresentedRequest>::encode(const BrowserFramePresentedRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_frame_seq = encode_value(value.frame_seq);
    if (!encoded_frame_seq) return std::move(encoded_frame_seq).error();
    object.emplace("frame_seq", std::move(encoded_frame_seq).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<BrowserFramePresentedRequest> Codec<BrowserFramePresentedRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserFramePresentedRequest result{};
    const Json* field_frame_seq = value.find("frame_seq");
    if (!field_frame_seq) {
        return make_error(ErrorCode::decode, "missing required field 'frame_seq'");
    }
    if (field_frame_seq) {
        auto decoded = decode_value<std::uint64_t>(*field_frame_seq);
        if (!decoded) return std::move(decoded).error();
        result.frame_seq = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserInsertTextRequest>::encode(const BrowserInsertTextRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    auto encoded_text = encode_value(value.text);
    if (!encoded_text) return std::move(encoded_text).error();
    object.emplace("text", std::move(encoded_text).value());
    return Json(std::move(object));
}

Result<BrowserInsertTextRequest> Codec<BrowserInsertTextRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserInsertTextRequest result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_text = value.find("text");
    if (!field_text) {
        return make_error(ErrorCode::decode, "missing required field 'text'");
    }
    if (field_text) {
        auto decoded = decode_value<std::string>(*field_text);
        if (!decoded) return std::move(decoded).error();
        result.text = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserKeyRequest>::encode(const BrowserKeyRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_code = encode_value(value.code);
    if (!encoded_code) return std::move(encoded_code).error();
    object.emplace("code", std::move(encoded_code).value());
    auto encoded_key = encode_value(value.key);
    if (!encoded_key) return std::move(encoded_key).error();
    object.emplace("key", std::move(encoded_key).value());
    auto encoded_kind = encode_value(value.kind);
    if (!encoded_kind) return std::move(encoded_kind).error();
    object.emplace("kind", std::move(encoded_kind).value());
    auto encoded_modifiers = encode_value(value.modifiers);
    if (!encoded_modifiers) return std::move(encoded_modifiers).error();
    object.emplace("modifiers", std::move(encoded_modifiers).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    if (!value.text.is_absent()) {
        auto encoded = encode_value(value.text);
        if (!encoded) return std::move(encoded).error();
        object.emplace("text", std::move(encoded).value());
    }
    auto encoded_windows_virtual_key_code = encode_value(value.windows_virtual_key_code);
    if (!encoded_windows_virtual_key_code) return std::move(encoded_windows_virtual_key_code).error();
    object.emplace("windows_virtual_key_code", std::move(encoded_windows_virtual_key_code).value());
    return Json(std::move(object));
}

Result<BrowserKeyRequest> Codec<BrowserKeyRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserKeyRequest result{};
    const Json* field_code = value.find("code");
    if (!field_code) {
        return make_error(ErrorCode::decode, "missing required field 'code'");
    }
    if (field_code) {
        auto decoded = decode_value<std::string>(*field_code);
        if (!decoded) return std::move(decoded).error();
        result.code = std::move(decoded).value();
    }
    const Json* field_key = value.find("key");
    if (!field_key) {
        return make_error(ErrorCode::decode, "missing required field 'key'");
    }
    if (field_key) {
        auto decoded = decode_value<std::string>(*field_key);
        if (!decoded) return std::move(decoded).error();
        result.key = std::move(decoded).value();
    }
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        auto decoded = decode_value<BrowserKeyRequestKind>(*field_kind);
        if (!decoded) return std::move(decoded).error();
        result.kind = std::move(decoded).value();
    }
    const Json* field_modifiers = value.find("modifiers");
    if (!field_modifiers) {
        return make_error(ErrorCode::decode, "missing required field 'modifiers'");
    }
    if (field_modifiers) {
        auto decoded = decode_value<std::uint32_t>(*field_modifiers);
        if (!decoded) return std::move(decoded).error();
        result.modifiers = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_text = value.find("text");
    if (field_text) {
        if (field_text->is_null()) {
            result.text = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_text);
            if (!decoded) return std::move(decoded).error();
            result.text = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_windows_virtual_key_code = value.find("windows_virtual_key_code");
    if (!field_windows_virtual_key_code) {
        return make_error(ErrorCode::decode, "missing required field 'windows_virtual_key_code'");
    }
    if (field_windows_virtual_key_code) {
        auto decoded = decode_value<std::uint32_t>(*field_windows_virtual_key_code);
        if (!decoded) return std::move(decoded).error();
        result.windows_virtual_key_code = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserKeyPressRequest>::encode(const BrowserKeyPressRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_code = encode_value(value.code);
    if (!encoded_code) return std::move(encoded_code).error();
    object.emplace("code", std::move(encoded_code).value());
    auto encoded_key = encode_value(value.key);
    if (!encoded_key) return std::move(encoded_key).error();
    object.emplace("key", std::move(encoded_key).value());
    auto encoded_modifiers = encode_value(value.modifiers);
    if (!encoded_modifiers) return std::move(encoded_modifiers).error();
    object.emplace("modifiers", std::move(encoded_modifiers).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    if (!value.text.is_absent()) {
        auto encoded = encode_value(value.text);
        if (!encoded) return std::move(encoded).error();
        object.emplace("text", std::move(encoded).value());
    }
    auto encoded_windows_virtual_key_code = encode_value(value.windows_virtual_key_code);
    if (!encoded_windows_virtual_key_code) return std::move(encoded_windows_virtual_key_code).error();
    object.emplace("windows_virtual_key_code", std::move(encoded_windows_virtual_key_code).value());
    return Json(std::move(object));
}

Result<BrowserKeyPressRequest> Codec<BrowserKeyPressRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserKeyPressRequest result{};
    const Json* field_code = value.find("code");
    if (!field_code) {
        return make_error(ErrorCode::decode, "missing required field 'code'");
    }
    if (field_code) {
        auto decoded = decode_value<std::string>(*field_code);
        if (!decoded) return std::move(decoded).error();
        result.code = std::move(decoded).value();
    }
    const Json* field_key = value.find("key");
    if (!field_key) {
        return make_error(ErrorCode::decode, "missing required field 'key'");
    }
    if (field_key) {
        auto decoded = decode_value<std::string>(*field_key);
        if (!decoded) return std::move(decoded).error();
        result.key = std::move(decoded).value();
    }
    const Json* field_modifiers = value.find("modifiers");
    if (!field_modifiers) {
        return make_error(ErrorCode::decode, "missing required field 'modifiers'");
    }
    if (field_modifiers) {
        auto decoded = decode_value<std::uint32_t>(*field_modifiers);
        if (!decoded) return std::move(decoded).error();
        result.modifiers = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_text = value.find("text");
    if (field_text) {
        if (field_text->is_null()) {
            result.text = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_text);
            if (!decoded) return std::move(decoded).error();
            result.text = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_windows_virtual_key_code = value.find("windows_virtual_key_code");
    if (!field_windows_virtual_key_code) {
        return make_error(ErrorCode::decode, "missing required field 'windows_virtual_key_code'");
    }
    if (field_windows_virtual_key_code) {
        auto decoded = decode_value<std::uint32_t>(*field_windows_virtual_key_code);
        if (!decoded) return std::move(decoded).error();
        result.windows_virtual_key_code = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserMouseRequest>::encode(const BrowserMouseRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.button.is_absent()) {
        auto encoded = encode_value(value.button);
        if (!encoded) return std::move(encoded).error();
        object.emplace("button", std::move(encoded).value());
    }
    if (!value.click_count.is_absent()) {
        auto encoded = encode_value(value.click_count);
        if (!encoded) return std::move(encoded).error();
        object.emplace("click_count", std::move(encoded).value());
    }
    if (!value.frame_seq.is_absent()) {
        auto encoded = encode_value(value.frame_seq);
        if (!encoded) return std::move(encoded).error();
        object.emplace("frame_seq", std::move(encoded).value());
    }
    auto encoded_kind = encode_value(value.kind);
    if (!encoded_kind) return std::move(encoded_kind).error();
    object.emplace("kind", std::move(encoded_kind).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    auto encoded_x_px = encode_value(value.x_px);
    if (!encoded_x_px) return std::move(encoded_x_px).error();
    object.emplace("x_px", std::move(encoded_x_px).value());
    auto encoded_y_px = encode_value(value.y_px);
    if (!encoded_y_px) return std::move(encoded_y_px).error();
    object.emplace("y_px", std::move(encoded_y_px).value());
    return Json(std::move(object));
}

Result<BrowserMouseRequest> Codec<BrowserMouseRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserMouseRequest result{};
    const Json* field_button = value.find("button");
    if (field_button) {
        if (field_button->is_null()) {
            result.button = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_button);
            if (!decoded) return std::move(decoded).error();
            result.button = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_click_count = value.find("click_count");
    if (field_click_count) {
        if (field_click_count->is_null()) {
            result.click_count = Field<std::uint32_t>::null();
        } else {
            auto decoded = decode_value<std::uint32_t>(*field_click_count);
            if (!decoded) return std::move(decoded).error();
            result.click_count = Field<std::uint32_t>(std::move(decoded).value());
        }
    }
    const Json* field_frame_seq = value.find("frame_seq");
    if (field_frame_seq) {
        if (field_frame_seq->is_null()) {
            result.frame_seq = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_frame_seq);
            if (!decoded) return std::move(decoded).error();
            result.frame_seq = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        auto decoded = decode_value<BrowserMouseRequestKind>(*field_kind);
        if (!decoded) return std::move(decoded).error();
        result.kind = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_x_px = value.find("x_px");
    if (!field_x_px) {
        return make_error(ErrorCode::decode, "missing required field 'x_px'");
    }
    if (field_x_px) {
        auto decoded = decode_value<double>(*field_x_px);
        if (!decoded) return std::move(decoded).error();
        result.x_px = std::move(decoded).value();
    }
    const Json* field_y_px = value.find("y_px");
    if (!field_y_px) {
        return make_error(ErrorCode::decode, "missing required field 'y_px'");
    }
    if (field_y_px) {
        auto decoded = decode_value<double>(*field_y_px);
        if (!decoded) return std::move(decoded).error();
        result.y_px = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserMouseGuardedRequest>::encode(const BrowserMouseGuardedRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.button.is_absent()) {
        auto encoded = encode_value(value.button);
        if (!encoded) return std::move(encoded).error();
        object.emplace("button", std::move(encoded).value());
    }
    if (!value.click_count.is_absent()) {
        auto encoded = encode_value(value.click_count);
        if (!encoded) return std::move(encoded).error();
        object.emplace("click_count", std::move(encoded).value());
    }
    auto encoded_frame_seq = encode_value(value.frame_seq);
    if (!encoded_frame_seq) return std::move(encoded_frame_seq).error();
    object.emplace("frame_seq", std::move(encoded_frame_seq).value());
    auto encoded_kind = encode_value(value.kind);
    if (!encoded_kind) return std::move(encoded_kind).error();
    object.emplace("kind", std::move(encoded_kind).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    auto encoded_x_px = encode_value(value.x_px);
    if (!encoded_x_px) return std::move(encoded_x_px).error();
    object.emplace("x_px", std::move(encoded_x_px).value());
    auto encoded_y_px = encode_value(value.y_px);
    if (!encoded_y_px) return std::move(encoded_y_px).error();
    object.emplace("y_px", std::move(encoded_y_px).value());
    return Json(std::move(object));
}

Result<BrowserMouseGuardedRequest> Codec<BrowserMouseGuardedRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserMouseGuardedRequest result{};
    const Json* field_button = value.find("button");
    if (field_button) {
        if (field_button->is_null()) {
            result.button = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_button);
            if (!decoded) return std::move(decoded).error();
            result.button = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_click_count = value.find("click_count");
    if (field_click_count) {
        if (field_click_count->is_null()) {
            result.click_count = Field<std::uint32_t>::null();
        } else {
            auto decoded = decode_value<std::uint32_t>(*field_click_count);
            if (!decoded) return std::move(decoded).error();
            result.click_count = Field<std::uint32_t>(std::move(decoded).value());
        }
    }
    const Json* field_frame_seq = value.find("frame_seq");
    if (!field_frame_seq) {
        return make_error(ErrorCode::decode, "missing required field 'frame_seq'");
    }
    if (field_frame_seq) {
        auto decoded = decode_value<std::uint64_t>(*field_frame_seq);
        if (!decoded) return std::move(decoded).error();
        result.frame_seq = std::move(decoded).value();
    }
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        auto decoded = decode_value<BrowserMouseGuardedRequestKind>(*field_kind);
        if (!decoded) return std::move(decoded).error();
        result.kind = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_x_px = value.find("x_px");
    if (!field_x_px) {
        return make_error(ErrorCode::decode, "missing required field 'x_px'");
    }
    if (field_x_px) {
        auto decoded = decode_value<double>(*field_x_px);
        if (!decoded) return std::move(decoded).error();
        result.x_px = std::move(decoded).value();
    }
    const Json* field_y_px = value.find("y_px");
    if (!field_y_px) {
        return make_error(ErrorCode::decode, "missing required field 'y_px'");
    }
    if (field_y_px) {
        auto decoded = decode_value<double>(*field_y_px);
        if (!decoded) return std::move(decoded).error();
        result.y_px = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserNavigateRequest>::encode(const BrowserNavigateRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    auto encoded_url = encode_value(value.url);
    if (!encoded_url) return std::move(encoded_url).error();
    object.emplace("url", std::move(encoded_url).value());
    return Json(std::move(object));
}

Result<BrowserNavigateRequest> Codec<BrowserNavigateRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserNavigateRequest result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_url = value.find("url");
    if (!field_url) {
        return make_error(ErrorCode::decode, "missing required field 'url'");
    }
    if (field_url) {
        auto decoded = decode_value<std::string>(*field_url);
        if (!decoded) return std::move(decoded).error();
        result.url = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserReloadRequest>::encode(const BrowserReloadRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<BrowserReloadRequest> Codec<BrowserReloadRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserReloadRequest result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserWheelRequest>::encode(const BrowserWheelRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_delta_y_px = encode_value(value.delta_y_px);
    if (!encoded_delta_y_px) return std::move(encoded_delta_y_px).error();
    object.emplace("delta_y_px", std::move(encoded_delta_y_px).value());
    if (!value.frame_seq.is_absent()) {
        auto encoded = encode_value(value.frame_seq);
        if (!encoded) return std::move(encoded).error();
        object.emplace("frame_seq", std::move(encoded).value());
    }
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    auto encoded_x_px = encode_value(value.x_px);
    if (!encoded_x_px) return std::move(encoded_x_px).error();
    object.emplace("x_px", std::move(encoded_x_px).value());
    auto encoded_y_px = encode_value(value.y_px);
    if (!encoded_y_px) return std::move(encoded_y_px).error();
    object.emplace("y_px", std::move(encoded_y_px).value());
    return Json(std::move(object));
}

Result<BrowserWheelRequest> Codec<BrowserWheelRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserWheelRequest result{};
    const Json* field_delta_y_px = value.find("delta_y_px");
    if (!field_delta_y_px) {
        return make_error(ErrorCode::decode, "missing required field 'delta_y_px'");
    }
    if (field_delta_y_px) {
        auto decoded = decode_value<double>(*field_delta_y_px);
        if (!decoded) return std::move(decoded).error();
        result.delta_y_px = std::move(decoded).value();
    }
    const Json* field_frame_seq = value.find("frame_seq");
    if (field_frame_seq) {
        if (field_frame_seq->is_null()) {
            result.frame_seq = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_frame_seq);
            if (!decoded) return std::move(decoded).error();
            result.frame_seq = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_x_px = value.find("x_px");
    if (!field_x_px) {
        return make_error(ErrorCode::decode, "missing required field 'x_px'");
    }
    if (field_x_px) {
        auto decoded = decode_value<double>(*field_x_px);
        if (!decoded) return std::move(decoded).error();
        result.x_px = std::move(decoded).value();
    }
    const Json* field_y_px = value.find("y_px");
    if (!field_y_px) {
        return make_error(ErrorCode::decode, "missing required field 'y_px'");
    }
    if (field_y_px) {
        auto decoded = decode_value<double>(*field_y_px);
        if (!decoded) return std::move(decoded).error();
        result.y_px = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<BrowserWheelGuardedRequest>::encode(const BrowserWheelGuardedRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_delta_y_px = encode_value(value.delta_y_px);
    if (!encoded_delta_y_px) return std::move(encoded_delta_y_px).error();
    object.emplace("delta_y_px", std::move(encoded_delta_y_px).value());
    auto encoded_frame_seq = encode_value(value.frame_seq);
    if (!encoded_frame_seq) return std::move(encoded_frame_seq).error();
    object.emplace("frame_seq", std::move(encoded_frame_seq).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    auto encoded_x_px = encode_value(value.x_px);
    if (!encoded_x_px) return std::move(encoded_x_px).error();
    object.emplace("x_px", std::move(encoded_x_px).value());
    auto encoded_y_px = encode_value(value.y_px);
    if (!encoded_y_px) return std::move(encoded_y_px).error();
    object.emplace("y_px", std::move(encoded_y_px).value());
    return Json(std::move(object));
}

Result<BrowserWheelGuardedRequest> Codec<BrowserWheelGuardedRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserWheelGuardedRequest result{};
    const Json* field_delta_y_px = value.find("delta_y_px");
    if (!field_delta_y_px) {
        return make_error(ErrorCode::decode, "missing required field 'delta_y_px'");
    }
    if (field_delta_y_px) {
        auto decoded = decode_value<double>(*field_delta_y_px);
        if (!decoded) return std::move(decoded).error();
        result.delta_y_px = std::move(decoded).value();
    }
    const Json* field_frame_seq = value.find("frame_seq");
    if (!field_frame_seq) {
        return make_error(ErrorCode::decode, "missing required field 'frame_seq'");
    }
    if (field_frame_seq) {
        auto decoded = decode_value<std::uint64_t>(*field_frame_seq);
        if (!decoded) return std::move(decoded).error();
        result.frame_seq = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_x_px = value.find("x_px");
    if (!field_x_px) {
        return make_error(ErrorCode::decode, "missing required field 'x_px'");
    }
    if (field_x_px) {
        auto decoded = decode_value<double>(*field_x_px);
        if (!decoded) return std::move(decoded).error();
        result.x_px = std::move(decoded).value();
    }
    const Json* field_y_px = value.find("y_px");
    if (!field_y_px) {
        return make_error(ErrorCode::decode, "missing required field 'y_px'");
    }
    if (field_y_px) {
        auto decoded = decode_value<double>(*field_y_px);
        if (!decoded) return std::move(decoded).error();
        result.y_px = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ClearHistoryRequest>::encode(const ClearHistoryRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.fallback_key.is_absent()) {
        auto encoded = encode_value(value.fallback_key);
        if (!encoded) return std::move(encoded).error();
        object.emplace("fallback_key", std::move(encoded).value());
    }
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<ClearHistoryRequest> Codec<ClearHistoryRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ClearHistoryRequest result{};
    const Json* field_fallback_key = value.find("fallback_key");
    if (field_fallback_key) {
        if (field_fallback_key->is_null()) {
            result.fallback_key = Field<TerminalKeyInput>::null();
        } else {
            auto decoded = decode_value<TerminalKeyInput>(*field_fallback_key);
            if (!decoded) return std::move(decoded).error();
            result.fallback_key = Field<TerminalKeyInput>(std::move(decoded).value());
        }
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ClearWindowTitleRequest>::encode(const ClearWindowTitleRequest& value) {
    (void)value;
    Json::Object object;
    return Json(std::move(object));
}

Result<ClearWindowTitleRequest> Codec<ClearWindowTitleRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ClearWindowTitleRequest result{};
    return result;
}

Result<Json> Codec<ClientFocusRequest>::encode(const ClientFocusRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_client_id = encode_value(value.client_id);
    if (!encoded_client_id) return std::move(encoded_client_id).error();
    object.emplace("client_id", std::move(encoded_client_id).value());
    return Json(std::move(object));
}

Result<ClientFocusRequest> Codec<ClientFocusRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ClientFocusRequest result{};
    const Json* field_client_id = value.find("client_id");
    if (!field_client_id) {
        return make_error(ErrorCode::decode, "missing required field 'client_id'");
    }
    if (field_client_id) {
        auto decoded = decode_value<std::string>(*field_client_id);
        if (!decoded) return std::move(decoded).error();
        result.client_id = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ClientFocusResult>::encode(const ClientFocusResult& value) {
    (void)value;
    Json::Object object;
    if (value.pane) {
        auto encoded = encode_value(*value.pane);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pane", std::move(encoded).value());
    } else {
        object.emplace("pane", Json(nullptr));
    }
    if (value.tab) {
        auto encoded = encode_value(*value.tab);
        if (!encoded) return std::move(encoded).error();
        object.emplace("tab", std::move(encoded).value());
    } else {
        object.emplace("tab", Json(nullptr));
    }
    return Json(std::move(object));
}

Result<ClientFocusResult> Codec<ClientFocusResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ClientFocusResult result{};
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        if (field_pane->is_null()) {
            result.pane.reset();
        } else {
            auto decoded = decode_value<Id>(*field_pane);
            if (!decoded) return std::move(decoded).error();
            result.pane = std::move(decoded).value();
        }
    }
    const Json* field_tab = value.find("tab");
    if (!field_tab) {
        return make_error(ErrorCode::decode, "missing required field 'tab'");
    }
    if (field_tab) {
        if (field_tab->is_null()) {
            result.tab.reset();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_tab);
            if (!decoded) return std::move(decoded).error();
            result.tab = std::move(decoded).value();
        }
    }
    return result;
}

Result<Json> Codec<ClosePaneRequest>::encode(const ClosePaneRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    return Json(std::move(object));
}

Result<ClosePaneRequest> Codec<ClosePaneRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ClosePaneRequest result{};
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<CloseProviderManagedWorkspaceRequest>::encode(const CloseProviderManagedWorkspaceRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_authority = encode_value(value.authority);
    if (!encoded_authority) return std::move(encoded_authority).error();
    object.emplace("authority", std::move(encoded_authority).value());
    auto encoded_key = encode_value(value.key);
    if (!encoded_key) return std::move(encoded_key).error();
    object.emplace("key", std::move(encoded_key).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    return Json(std::move(object));
}

Result<CloseProviderManagedWorkspaceRequest> Codec<CloseProviderManagedWorkspaceRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    CloseProviderManagedWorkspaceRequest result{};
    const Json* field_authority = value.find("authority");
    if (!field_authority) {
        return make_error(ErrorCode::decode, "missing required field 'authority'");
    }
    if (field_authority) {
        auto decoded = decode_value<std::string>(*field_authority);
        if (!decoded) return std::move(decoded).error();
        result.authority = std::move(decoded).value();
    }
    const Json* field_key = value.find("key");
    if (!field_key) {
        return make_error(ErrorCode::decode, "missing required field 'key'");
    }
    if (field_key) {
        auto decoded = decode_value<std::string>(*field_key);
        if (!decoded) return std::move(decoded).error();
        result.key = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<CloseScreenRequest>::encode(const CloseScreenRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_screen = encode_value(value.screen);
    if (!encoded_screen) return std::move(encoded_screen).error();
    object.emplace("screen", std::move(encoded_screen).value());
    return Json(std::move(object));
}

Result<CloseScreenRequest> Codec<CloseScreenRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    CloseScreenRequest result{};
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        auto decoded = decode_value<Id>(*field_screen);
        if (!decoded) return std::move(decoded).error();
        result.screen = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<CloseSurfaceRequest>::encode(const CloseSurfaceRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<CloseSurfaceRequest> Codec<CloseSurfaceRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    CloseSurfaceRequest result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<CloseTerminalRequest>::encode(const CloseTerminalRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.expected_generation.is_absent()) {
        auto encoded = encode_value(value.expected_generation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_generation", std::move(encoded).value());
    }
    if (!value.expected_revision.is_absent()) {
        auto encoded = encode_value(value.expected_revision);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_revision", std::move(encoded).value());
    }
    if (!value.mutation_id.is_absent()) {
        auto encoded = encode_value(value.mutation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("mutation_id", std::move(encoded).value());
    }
    if (!value.origin.is_absent()) {
        auto encoded = encode_value(value.origin);
        if (!encoded) return std::move(encoded).error();
        object.emplace("origin", std::move(encoded).value());
    }
    auto encoded_terminal_id = encode_value(value.terminal_id);
    if (!encoded_terminal_id) return std::move(encoded_terminal_id).error();
    object.emplace("terminal_id", std::move(encoded_terminal_id).value());
    if (!value.terminal_incarnation.is_absent()) {
        auto encoded = encode_value(value.terminal_incarnation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal_incarnation", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<CloseTerminalRequest> Codec<CloseTerminalRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    CloseTerminalRequest result{};
    const Json* field_expected_generation = value.find("expected_generation");
    if (field_expected_generation) {
        if (field_expected_generation->is_null()) {
            result.expected_generation = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_expected_generation);
            if (!decoded) return std::move(decoded).error();
            result.expected_generation = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_expected_revision = value.find("expected_revision");
    if (!field_expected_revision) {
        field_expected_revision = value.find("expected_terminal_revision");
    }
    if (field_expected_revision) {
        if (field_expected_revision->is_null()) {
            result.expected_revision = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_expected_revision);
            if (!decoded) return std::move(decoded).error();
            result.expected_revision = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    const Json* field_mutation_id = value.find("mutation_id");
    if (field_mutation_id) {
        if (field_mutation_id->is_null()) {
            result.mutation_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_mutation_id);
            if (!decoded) return std::move(decoded).error();
            result.mutation_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_origin = value.find("origin");
    if (field_origin) {
        if (field_origin->is_null()) {
            result.origin = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_origin);
            if (!decoded) return std::move(decoded).error();
            result.origin = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_terminal_id = value.find("terminal_id");
    if (!field_terminal_id) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_id'");
    }
    if (field_terminal_id) {
        auto decoded = decode_value<std::string>(*field_terminal_id);
        if (!decoded) return std::move(decoded).error();
        result.terminal_id = std::move(decoded).value();
    }
    const Json* field_terminal_incarnation = value.find("terminal_incarnation");
    if (field_terminal_incarnation) {
        if (field_terminal_incarnation->is_null()) {
            result.terminal_incarnation = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_terminal_incarnation);
            if (!decoded) return std::move(decoded).error();
            result.terminal_incarnation = Field<std::string>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<CloseWorkspaceRequest>::encode(const CloseWorkspaceRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.expected_generation.is_absent()) {
        auto encoded = encode_value(value.expected_generation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_generation", std::move(encoded).value());
    }
    if (!value.expected_revision.is_absent()) {
        auto encoded = encode_value(value.expected_revision);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_revision", std::move(encoded).value());
    }
    if (!value.key.is_absent()) {
        auto encoded = encode_value(value.key);
        if (!encoded) return std::move(encoded).error();
        object.emplace("key", std::move(encoded).value());
    }
    if (!value.mutation_id.is_absent()) {
        auto encoded = encode_value(value.mutation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("mutation_id", std::move(encoded).value());
    }
    if (!value.origin.is_absent()) {
        auto encoded = encode_value(value.origin);
        if (!encoded) return std::move(encoded).error();
        object.emplace("origin", std::move(encoded).value());
    }
    if (!value.workspace.is_absent()) {
        auto encoded = encode_value(value.workspace);
        if (!encoded) return std::move(encoded).error();
        object.emplace("workspace", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<CloseWorkspaceRequest> Codec<CloseWorkspaceRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    CloseWorkspaceRequest result{};
    const Json* field_expected_generation = value.find("expected_generation");
    if (field_expected_generation) {
        if (field_expected_generation->is_null()) {
            result.expected_generation = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_expected_generation);
            if (!decoded) return std::move(decoded).error();
            result.expected_generation = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_expected_revision = value.find("expected_revision");
    if (!field_expected_revision) {
        field_expected_revision = value.find("expected_terminal_revision");
    }
    if (field_expected_revision) {
        if (field_expected_revision->is_null()) {
            result.expected_revision = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_expected_revision);
            if (!decoded) return std::move(decoded).error();
            result.expected_revision = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    const Json* field_key = value.find("key");
    if (field_key) {
        if (field_key->is_null()) {
            result.key = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_key);
            if (!decoded) return std::move(decoded).error();
            result.key = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_mutation_id = value.find("mutation_id");
    if (field_mutation_id) {
        if (field_mutation_id->is_null()) {
            result.mutation_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_mutation_id);
            if (!decoded) return std::move(decoded).error();
            result.mutation_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_origin = value.find("origin");
    if (field_origin) {
        if (field_origin->is_null()) {
            result.origin = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_origin);
            if (!decoded) return std::move(decoded).error();
            result.origin = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_workspace = value.find("workspace");
    if (field_workspace) {
        if (field_workspace->is_null()) {
            result.workspace = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_workspace);
            if (!decoded) return std::move(decoded).error();
            result.workspace = Field<Id>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<CopyRequest>::encode(const CopyRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_mode = encode_value(value.mode);
    if (!encoded_mode) return std::move(encoded_mode).error();
    object.emplace("mode", std::move(encoded_mode).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<CopyRequest> Codec<CopyRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    CopyRequest result{};
    const Json* field_mode = value.find("mode");
    if (!field_mode) {
        return make_error(ErrorCode::decode, "missing required field 'mode'");
    }
    if (field_mode) {
        auto decoded = decode_value<CopyRequestMode>(*field_mode);
        if (!decoded) return std::move(decoded).error();
        result.mode = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<CreateSurfaceWithReceiptRequest>::encode(const CreateSurfaceWithReceiptRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.argv.is_absent()) {
        auto encoded = encode_value(value.argv);
        if (!encoded) return std::move(encoded).error();
        object.emplace("argv", std::move(encoded).value());
    }
    if (!value.cols.is_absent()) {
        auto encoded = encode_value(value.cols);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cols", std::move(encoded).value());
    }
    if (!value.cwd.is_absent()) {
        auto encoded = encode_value(value.cwd);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cwd", std::move(encoded).value());
    }
    if (!value.idempotency_key.is_absent()) {
        auto encoded = encode_value(value.idempotency_key);
        if (!encoded) return std::move(encoded).error();
        object.emplace("idempotency_key", std::move(encoded).value());
    }
    auto encoded_operation = encode_value(value.operation);
    if (!encoded_operation) return std::move(encoded_operation).error();
    object.emplace("operation", std::move(encoded_operation).value());
    auto encoded_origin = encode_value(value.origin);
    if (!encoded_origin) return std::move(encoded_origin).error();
    object.emplace("origin", std::move(encoded_origin).value());
    if (!value.pane.is_absent()) {
        auto encoded = encode_value(value.pane);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pane", std::move(encoded).value());
    }
    auto encoded_receipt = encode_value(value.receipt);
    if (!encoded_receipt) return std::move(encoded_receipt).error();
    object.emplace("receipt", std::move(encoded_receipt).value());
    if (!value.rows.is_absent()) {
        auto encoded = encode_value(value.rows);
        if (!encoded) return std::move(encoded).error();
        object.emplace("rows", std::move(encoded).value());
    }
    if (value.selector_fallbacks) {
        auto encoded = encode_value(*value.selector_fallbacks);
        if (!encoded) return std::move(encoded).error();
        object.emplace("selector_fallbacks", std::move(encoded).value());
    }
    if (!value.selectors.is_absent()) {
        auto encoded = encode_value(value.selectors);
        if (!encoded) return std::move(encoded).error();
        object.emplace("selectors", std::move(encoded).value());
    }
    if (!value.url.is_absent()) {
        auto encoded = encode_value(value.url);
        if (!encoded) return std::move(encoded).error();
        object.emplace("url", std::move(encoded).value());
    }
    if (!value.width.is_absent()) {
        auto encoded = encode_value(value.width);
        if (!encoded) return std::move(encoded).error();
        object.emplace("width", std::move(encoded).value());
    }
    if (!value.workspace.is_absent()) {
        auto encoded = encode_value(value.workspace);
        if (!encoded) return std::move(encoded).error();
        object.emplace("workspace", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<CreateSurfaceWithReceiptRequest> Codec<CreateSurfaceWithReceiptRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    CreateSurfaceWithReceiptRequest result{};
    const Json* field_argv = value.find("argv");
    if (field_argv) {
        if (field_argv->is_null()) {
            result.argv = Field<std::vector<std::string>>::null();
        } else {
            auto decoded = decode_value<std::vector<std::string>>(*field_argv);
            if (!decoded) return std::move(decoded).error();
            result.argv = Field<std::vector<std::string>>(std::move(decoded).value());
        }
    }
    const Json* field_cols = value.find("cols");
    if (field_cols) {
        if (field_cols->is_null()) {
            result.cols = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_cols);
            if (!decoded) return std::move(decoded).error();
            result.cols = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_cwd = value.find("cwd");
    if (field_cwd) {
        if (field_cwd->is_null()) {
            result.cwd = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_cwd);
            if (!decoded) return std::move(decoded).error();
            result.cwd = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_idempotency_key = value.find("idempotency_key");
    if (field_idempotency_key) {
        if (field_idempotency_key->is_null()) {
            result.idempotency_key = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_idempotency_key);
            if (!decoded) return std::move(decoded).error();
            result.idempotency_key = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_operation = value.find("operation");
    if (!field_operation) {
        return make_error(ErrorCode::decode, "missing required field 'operation'");
    }
    if (field_operation) {
        auto decoded = decode_value<std::string>(*field_operation);
        if (!decoded) return std::move(decoded).error();
        result.operation = std::move(decoded).value();
    }
    const Json* field_origin = value.find("origin");
    if (!field_origin) {
        return make_error(ErrorCode::decode, "missing required field 'origin'");
    }
    if (field_origin) {
        auto decoded = decode_value<std::string>(*field_origin);
        if (!decoded) return std::move(decoded).error();
        result.origin = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (field_pane) {
        if (field_pane->is_null()) {
            result.pane = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_pane);
            if (!decoded) return std::move(decoded).error();
            result.pane = Field<Id>(std::move(decoded).value());
        }
    }
    const Json* field_receipt = value.find("receipt");
    if (!field_receipt) {
        return make_error(ErrorCode::decode, "missing required field 'receipt'");
    }
    if (field_receipt) {
        auto decoded = decode_value<std::string>(*field_receipt);
        if (!decoded) return std::move(decoded).error();
        result.receipt = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (field_rows) {
        if (field_rows->is_null()) {
            result.rows = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_rows);
            if (!decoded) return std::move(decoded).error();
            result.rows = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_selector_fallbacks = value.find("selector_fallbacks");
    if (field_selector_fallbacks) {
        auto decoded = decode_value<std::vector<ResourceSelectors>>(*field_selector_fallbacks);
        if (!decoded) return std::move(decoded).error();
        result.selector_fallbacks = std::move(decoded).value();
    }
    const Json* field_selectors = value.find("selectors");
    if (field_selectors) {
        if (field_selectors->is_null()) {
            result.selectors = Field<ResourceSelectors>::null();
        } else {
            auto decoded = decode_value<ResourceSelectors>(*field_selectors);
            if (!decoded) return std::move(decoded).error();
            result.selectors = Field<ResourceSelectors>(std::move(decoded).value());
        }
    }
    const Json* field_url = value.find("url");
    if (field_url) {
        if (field_url->is_null()) {
            result.url = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_url);
            if (!decoded) return std::move(decoded).error();
            result.url = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_width = value.find("width");
    if (field_width) {
        if (field_width->is_null()) {
            result.width = Field<float>::null();
        } else {
            auto decoded = decode_value<float>(*field_width);
            if (!decoded) return std::move(decoded).error();
            result.width = Field<float>(std::move(decoded).value());
        }
    }
    const Json* field_workspace = value.find("workspace");
    if (field_workspace) {
        if (field_workspace->is_null()) {
            result.workspace = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_workspace);
            if (!decoded) return std::move(decoded).error();
            result.workspace = Field<Id>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<CreateTerminalRequest>::encode(const CreateTerminalRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.argv.is_absent()) {
        auto encoded = encode_value(value.argv);
        if (!encoded) return std::move(encoded).error();
        object.emplace("argv", std::move(encoded).value());
    }
    if (!value.cols.is_absent()) {
        auto encoded = encode_value(value.cols);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cols", std::move(encoded).value());
    }
    if (!value.command.is_absent()) {
        auto encoded = encode_value(value.command);
        if (!encoded) return std::move(encoded).error();
        object.emplace("command", std::move(encoded).value());
    }
    if (!value.cwd.is_absent()) {
        auto encoded = encode_value(value.cwd);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cwd", std::move(encoded).value());
    }
    if (!value.expected_generation.is_absent()) {
        auto encoded = encode_value(value.expected_generation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_generation", std::move(encoded).value());
    }
    if (!value.expected_revision.is_absent()) {
        auto encoded = encode_value(value.expected_revision);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_revision", std::move(encoded).value());
    }
    if (!value.key.is_absent()) {
        auto encoded = encode_value(value.key);
        if (!encoded) return std::move(encoded).error();
        object.emplace("key", std::move(encoded).value());
    }
    if (!value.mutation_id.is_absent()) {
        auto encoded = encode_value(value.mutation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("mutation_id", std::move(encoded).value());
    }
    if (!value.name.is_absent()) {
        auto encoded = encode_value(value.name);
        if (!encoded) return std::move(encoded).error();
        object.emplace("name", std::move(encoded).value());
    }
    if (!value.origin.is_absent()) {
        auto encoded = encode_value(value.origin);
        if (!encoded) return std::move(encoded).error();
        object.emplace("origin", std::move(encoded).value());
    }
    if (!value.rows.is_absent()) {
        auto encoded = encode_value(value.rows);
        if (!encoded) return std::move(encoded).error();
        object.emplace("rows", std::move(encoded).value());
    }
    if (!value.terminal_id.is_absent()) {
        auto encoded = encode_value(value.terminal_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal_id", std::move(encoded).value());
    }
    if (!value.workspace.is_absent()) {
        auto encoded = encode_value(value.workspace);
        if (!encoded) return std::move(encoded).error();
        object.emplace("workspace", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<CreateTerminalRequest> Codec<CreateTerminalRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    CreateTerminalRequest result{};
    const Json* field_argv = value.find("argv");
    if (field_argv) {
        if (field_argv->is_null()) {
            result.argv = Field<std::vector<std::string>>::null();
        } else {
            auto decoded = decode_value<std::vector<std::string>>(*field_argv);
            if (!decoded) return std::move(decoded).error();
            result.argv = Field<std::vector<std::string>>(std::move(decoded).value());
        }
    }
    const Json* field_cols = value.find("cols");
    if (field_cols) {
        if (field_cols->is_null()) {
            result.cols = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_cols);
            if (!decoded) return std::move(decoded).error();
            result.cols = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_command = value.find("command");
    if (field_command) {
        if (field_command->is_null()) {
            result.command = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_command);
            if (!decoded) return std::move(decoded).error();
            result.command = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_cwd = value.find("cwd");
    if (field_cwd) {
        if (field_cwd->is_null()) {
            result.cwd = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_cwd);
            if (!decoded) return std::move(decoded).error();
            result.cwd = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_expected_generation = value.find("expected_generation");
    if (field_expected_generation) {
        if (field_expected_generation->is_null()) {
            result.expected_generation = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_expected_generation);
            if (!decoded) return std::move(decoded).error();
            result.expected_generation = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_expected_revision = value.find("expected_revision");
    if (!field_expected_revision) {
        field_expected_revision = value.find("expected_terminal_revision");
    }
    if (field_expected_revision) {
        if (field_expected_revision->is_null()) {
            result.expected_revision = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_expected_revision);
            if (!decoded) return std::move(decoded).error();
            result.expected_revision = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    const Json* field_key = value.find("key");
    if (field_key) {
        if (field_key->is_null()) {
            result.key = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_key);
            if (!decoded) return std::move(decoded).error();
            result.key = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_mutation_id = value.find("mutation_id");
    if (field_mutation_id) {
        if (field_mutation_id->is_null()) {
            result.mutation_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_mutation_id);
            if (!decoded) return std::move(decoded).error();
            result.mutation_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_name = value.find("name");
    if (field_name) {
        if (field_name->is_null()) {
            result.name = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_name);
            if (!decoded) return std::move(decoded).error();
            result.name = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_origin = value.find("origin");
    if (field_origin) {
        if (field_origin->is_null()) {
            result.origin = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_origin);
            if (!decoded) return std::move(decoded).error();
            result.origin = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_rows = value.find("rows");
    if (field_rows) {
        if (field_rows->is_null()) {
            result.rows = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_rows);
            if (!decoded) return std::move(decoded).error();
            result.rows = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_terminal_id = value.find("terminal_id");
    if (field_terminal_id) {
        if (field_terminal_id->is_null()) {
            result.terminal_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_terminal_id);
            if (!decoded) return std::move(decoded).error();
            result.terminal_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_workspace = value.find("workspace");
    if (field_workspace) {
        if (field_workspace->is_null()) {
            result.workspace = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_workspace);
            if (!decoded) return std::move(decoded).error();
            result.workspace = Field<Id>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<CreateWorkspaceRequest>::encode(const CreateWorkspaceRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.expected_generation.is_absent()) {
        auto encoded = encode_value(value.expected_generation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_generation", std::move(encoded).value());
    }
    if (!value.expected_revision.is_absent()) {
        auto encoded = encode_value(value.expected_revision);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_revision", std::move(encoded).value());
    }
    if (!value.key.is_absent()) {
        auto encoded = encode_value(value.key);
        if (!encoded) return std::move(encoded).error();
        object.emplace("key", std::move(encoded).value());
    }
    if (!value.mutation_id.is_absent()) {
        auto encoded = encode_value(value.mutation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("mutation_id", std::move(encoded).value());
    }
    if (!value.name.is_absent()) {
        auto encoded = encode_value(value.name);
        if (!encoded) return std::move(encoded).error();
        object.emplace("name", std::move(encoded).value());
    }
    if (!value.origin.is_absent()) {
        auto encoded = encode_value(value.origin);
        if (!encoded) return std::move(encoded).error();
        object.emplace("origin", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<CreateWorkspaceRequest> Codec<CreateWorkspaceRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    CreateWorkspaceRequest result{};
    const Json* field_expected_generation = value.find("expected_generation");
    if (field_expected_generation) {
        if (field_expected_generation->is_null()) {
            result.expected_generation = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_expected_generation);
            if (!decoded) return std::move(decoded).error();
            result.expected_generation = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_expected_revision = value.find("expected_revision");
    if (!field_expected_revision) {
        field_expected_revision = value.find("expected_terminal_revision");
    }
    if (field_expected_revision) {
        if (field_expected_revision->is_null()) {
            result.expected_revision = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_expected_revision);
            if (!decoded) return std::move(decoded).error();
            result.expected_revision = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    const Json* field_key = value.find("key");
    if (field_key) {
        if (field_key->is_null()) {
            result.key = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_key);
            if (!decoded) return std::move(decoded).error();
            result.key = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_mutation_id = value.find("mutation_id");
    if (field_mutation_id) {
        if (field_mutation_id->is_null()) {
            result.mutation_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_mutation_id);
            if (!decoded) return std::move(decoded).error();
            result.mutation_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_name = value.find("name");
    if (field_name) {
        if (field_name->is_null()) {
            result.name = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_name);
            if (!decoded) return std::move(decoded).error();
            result.name = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_origin = value.find("origin");
    if (field_origin) {
        if (field_origin->is_null()) {
            result.origin = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_origin);
            if (!decoded) return std::move(decoded).error();
            result.origin = Field<std::string>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<DetachAttachedViewRequest>::encode(const DetachAttachedViewRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_lease = encode_value(value.lease);
    if (!encoded_lease) return std::move(encoded_lease).error();
    object.emplace("lease", std::move(encoded_lease).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<DetachAttachedViewRequest> Codec<DetachAttachedViewRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    DetachAttachedViewRequest result{};
    const Json* field_lease = value.find("lease");
    if (!field_lease) {
        return make_error(ErrorCode::decode, "missing required field 'lease'");
    }
    if (field_lease) {
        auto decoded = decode_value<std::string>(*field_lease);
        if (!decoded) return std::move(decoded).error();
        result.lease = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<DetachClientRequest>::encode(const DetachClientRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_client = encode_value(value.client);
    if (!encoded_client) return std::move(encoded_client).error();
    object.emplace("client", std::move(encoded_client).value());
    return Json(std::move(object));
}

Result<DetachClientRequest> Codec<DetachClientRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    DetachClientRequest result{};
    const Json* field_client = value.find("client");
    if (!field_client) {
        return make_error(ErrorCode::decode, "missing required field 'client'");
    }
    if (field_client) {
        auto decoded = decode_value<std::uint64_t>(*field_client);
        if (!decoded) return std::move(decoded).error();
        result.client = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ExportLayoutRequest>::encode(const ExportLayoutRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.screen.is_absent()) {
        auto encoded = encode_value(value.screen);
        if (!encoded) return std::move(encoded).error();
        object.emplace("screen", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<ExportLayoutRequest> Codec<ExportLayoutRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ExportLayoutRequest result{};
    const Json* field_screen = value.find("screen");
    if (field_screen) {
        if (field_screen->is_null()) {
            result.screen = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_screen);
            if (!decoded) return std::move(decoded).error();
            result.screen = Field<Id>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<FocusDirectionRequest>::encode(const FocusDirectionRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_dir = encode_value(value.dir);
    if (!encoded_dir) return std::move(encoded_dir).error();
    object.emplace("dir", std::move(encoded_dir).value());
    if (!value.pane.is_absent()) {
        auto encoded = encode_value(value.pane);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pane", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<FocusDirectionRequest> Codec<FocusDirectionRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    FocusDirectionRequest result{};
    const Json* field_dir = value.find("dir");
    if (!field_dir) {
        return make_error(ErrorCode::decode, "missing required field 'dir'");
    }
    if (field_dir) {
        auto decoded = decode_value<PaneDirection>(*field_dir);
        if (!decoded) return std::move(decoded).error();
        result.dir = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (field_pane) {
        if (field_pane->is_null()) {
            result.pane = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_pane);
            if (!decoded) return std::move(decoded).error();
            result.pane = Field<Id>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<FocusPaneRequest>::encode(const FocusPaneRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    return Json(std::move(object));
}

Result<FocusPaneRequest> Codec<FocusPaneRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    FocusPaneRequest result{};
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<GetBrowserProviderRequest>::encode(const GetBrowserProviderRequest& value) {
    (void)value;
    Json::Object object;
    return Json(std::move(object));
}

Result<GetBrowserProviderRequest> Codec<GetBrowserProviderRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    GetBrowserProviderRequest result{};
    return result;
}

Result<Json> Codec<GetCellPixelsRequest>::encode(const GetCellPixelsRequest& value) {
    (void)value;
    Json::Object object;
    return Json(std::move(object));
}

Result<GetCellPixelsRequest> Codec<GetCellPixelsRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    GetCellPixelsRequest result{};
    return result;
}

Result<Json> Codec<GetFrontendProjectionRequest>::encode(const GetFrontendProjectionRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_frontend = encode_value(value.frontend);
    if (!encoded_frontend) return std::move(encoded_frontend).error();
    object.emplace("frontend", std::move(encoded_frontend).value());
    auto encoded_scope = encode_value(value.scope);
    if (!encoded_scope) return std::move(encoded_scope).error();
    object.emplace("scope", std::move(encoded_scope).value());
    auto encoded_subject_key = encode_value(value.subject_key);
    if (!encoded_subject_key) return std::move(encoded_subject_key).error();
    object.emplace("subject_key", std::move(encoded_subject_key).value());
    return Json(std::move(object));
}

Result<GetFrontendProjectionRequest> Codec<GetFrontendProjectionRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    GetFrontendProjectionRequest result{};
    const Json* field_frontend = value.find("frontend");
    if (!field_frontend) {
        return make_error(ErrorCode::decode, "missing required field 'frontend'");
    }
    if (field_frontend) {
        auto decoded = decode_value<std::string>(*field_frontend);
        if (!decoded) return std::move(decoded).error();
        result.frontend = std::move(decoded).value();
    }
    const Json* field_scope = value.find("scope");
    if (!field_scope) {
        return make_error(ErrorCode::decode, "missing required field 'scope'");
    }
    if (field_scope) {
        auto decoded = decode_value<std::string>(*field_scope);
        if (!decoded) return std::move(decoded).error();
        result.scope = std::move(decoded).value();
    }
    const Json* field_subject_key = value.find("subject_key");
    if (!field_subject_key) {
        return make_error(ErrorCode::decode, "missing required field 'subject_key'");
    }
    if (field_subject_key) {
        auto decoded = decode_value<std::string>(*field_subject_key);
        if (!decoded) return std::move(decoded).error();
        result.subject_key = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<IdentifyRequest>::encode(const IdentifyRequest& value) {
    (void)value;
    Json::Object object;
    return Json(std::move(object));
}

Result<IdentifyRequest> Codec<IdentifyRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    IdentifyRequest result{};
    return result;
}

Result<Json> Codec<IdsRequest>::encode(const IdsRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.kind.is_absent()) {
        auto encoded = encode_value(value.kind);
        if (!encoded) return std::move(encoded).error();
        object.emplace("kind", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<IdsRequest> Codec<IdsRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    IdsRequest result{};
    const Json* field_kind = value.find("kind");
    if (field_kind) {
        if (field_kind->is_null()) {
            result.kind = Field<IdsRequestKind>::null();
        } else {
            auto decoded = decode_value<IdsRequestKind>(*field_kind);
            if (!decoded) return std::move(decoded).error();
            result.kind = Field<IdsRequestKind>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<JournalFrontendEventRequest>::encode(const JournalFrontendEventRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_event = encode_value(value.event);
    if (!encoded_event) return std::move(encoded_event).error();
    object.emplace("event", std::move(encoded_event).value());
    return Json(std::move(object));
}

Result<JournalFrontendEventRequest> Codec<JournalFrontendEventRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    JournalFrontendEventRequest result{};
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        auto decoded = decode_value<FrontendJournalEvent>(*field_event);
        if (!decoded) return std::move(decoded).error();
        result.event = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<JournalFrontendEventResult>::encode(const JournalFrontendEventResult& value) {
    (void)value;
    Json::Object object;
    object.emplace("committed", Json(true));
    return Json(std::move(object));
}

Result<JournalFrontendEventResult> Codec<JournalFrontendEventResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    JournalFrontendEventResult result{};
    const Json* field_committed = value.find("committed");
    if (!field_committed) {
        return make_error(ErrorCode::decode, "missing required field 'committed'");
    }
    if (field_committed) {
        if (*field_committed != Json(true)) {
            return make_error(ErrorCode::decode, "field 'committed' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<ListAgentsRequest>::encode(const ListAgentsRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.state.is_absent()) {
        auto encoded = encode_value(value.state);
        if (!encoded) return std::move(encoded).error();
        object.emplace("state", std::move(encoded).value());
    }
    if (!value.surface.is_absent()) {
        auto encoded = encode_value(value.surface);
        if (!encoded) return std::move(encoded).error();
        object.emplace("surface", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<ListAgentsRequest> Codec<ListAgentsRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ListAgentsRequest result{};
    const Json* field_state = value.find("state");
    if (field_state) {
        if (field_state->is_null()) {
            result.state = Field<AgentState>::null();
        } else {
            auto decoded = decode_value<AgentState>(*field_state);
            if (!decoded) return std::move(decoded).error();
            result.state = Field<AgentState>(std::move(decoded).value());
        }
    }
    const Json* field_surface = value.find("surface");
    if (field_surface) {
        if (field_surface->is_null()) {
            result.surface = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_surface);
            if (!decoded) return std::move(decoded).error();
            result.surface = Field<Id>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<ListClientsRequest>::encode(const ListClientsRequest& value) {
    (void)value;
    Json::Object object;
    return Json(std::move(object));
}

Result<ListClientsRequest> Codec<ListClientsRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ListClientsRequest result{};
    return result;
}

Result<Json> Codec<ListClientsResult>::encode(const ListClientsResult& value) {
    return encode_value(value.value);
}

Result<ListClientsResult> Codec<ListClientsResult>::decode(const Json& value) {
    auto decoded = decode_value<std::vector<ClientInfo>>(value);
    if (!decoded) return std::move(decoded).error();
    return ListClientsResult{std::move(decoded).value()};
}

Result<Json> Codec<ListTerminalsRequest>::encode(const ListTerminalsRequest& value) {
    (void)value;
    Json::Object object;
    return Json(std::move(object));
}

Result<ListTerminalsRequest> Codec<ListTerminalsRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ListTerminalsRequest result{};
    return result;
}

Result<Json> Codec<ListWorkspacesRequest>::encode(const ListWorkspacesRequest& value) {
    (void)value;
    Json::Object object;
    return Json(std::move(object));
}

Result<ListWorkspacesRequest> Codec<ListWorkspacesRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ListWorkspacesRequest result{};
    return result;
}

Result<Json> Codec<MarkWorkspacesProviderManagedRequest>::encode(const MarkWorkspacesProviderManagedRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_authority = encode_value(value.authority);
    if (!encoded_authority) return std::move(encoded_authority).error();
    object.emplace("authority", std::move(encoded_authority).value());
    return Json(std::move(object));
}

Result<MarkWorkspacesProviderManagedRequest> Codec<MarkWorkspacesProviderManagedRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    MarkWorkspacesProviderManagedRequest result{};
    const Json* field_authority = value.find("authority");
    if (!field_authority) {
        return make_error(ErrorCode::decode, "missing required field 'authority'");
    }
    if (field_authority) {
        auto decoded = decode_value<std::string>(*field_authority);
        if (!decoded) return std::move(decoded).error();
        result.authority = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<MintTerminalRendererRequest>::encode(const MintTerminalRendererRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    if (value.ttl_ms) {
        auto encoded = encode_value(*value.ttl_ms);
        if (!encoded) return std::move(encoded).error();
        object.emplace("ttl_ms", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<MintTerminalRendererRequest> Codec<MintTerminalRendererRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    MintTerminalRendererRequest result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_ttl_ms = value.find("ttl_ms");
    if (field_ttl_ms) {
        auto decoded = decode_value<std::uint64_t>(*field_ttl_ms);
        if (!decoded) return std::move(decoded).error();
        result.ttl_ms = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<MintTerminalRendererByTerminalRequest>::encode(const MintTerminalRendererByTerminalRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_terminal = encode_value(value.terminal);
    if (!encoded_terminal) return std::move(encoded_terminal).error();
    object.emplace("terminal", std::move(encoded_terminal).value());
    if (value.ttl_ms) {
        auto encoded = encode_value(*value.ttl_ms);
        if (!encoded) return std::move(encoded).error();
        object.emplace("ttl_ms", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<MintTerminalRendererByTerminalRequest> Codec<MintTerminalRendererByTerminalRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    MintTerminalRendererByTerminalRequest result{};
    const Json* field_terminal = value.find("terminal");
    if (!field_terminal) {
        return make_error(ErrorCode::decode, "missing required field 'terminal'");
    }
    if (field_terminal) {
        auto decoded = decode_value<std::string>(*field_terminal);
        if (!decoded) return std::move(decoded).error();
        result.terminal = std::move(decoded).value();
    }
    const Json* field_ttl_ms = value.find("ttl_ms");
    if (field_ttl_ms) {
        auto decoded = decode_value<std::uint64_t>(*field_ttl_ms);
        if (!decoded) return std::move(decoded).error();
        result.ttl_ms = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<MoveTabRequest>::encode(const MoveTabRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_index = encode_value(value.index);
    if (!encoded_index) return std::move(encoded_index).error();
    object.emplace("index", std::move(encoded_index).value());
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<MoveTabRequest> Codec<MoveTabRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    MoveTabRequest result{};
    const Json* field_index = value.find("index");
    if (!field_index) {
        return make_error(ErrorCode::decode, "missing required field 'index'");
    }
    if (field_index) {
        auto decoded = decode_value<std::uint64_t>(*field_index);
        if (!decoded) return std::move(decoded).error();
        result.index = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<MoveTerminalRequest>::encode(const MoveTerminalRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.expected_generation.is_absent()) {
        auto encoded = encode_value(value.expected_generation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_generation", std::move(encoded).value());
    }
    if (!value.expected_revision.is_absent()) {
        auto encoded = encode_value(value.expected_revision);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_revision", std::move(encoded).value());
    }
    if (!value.mutation_id.is_absent()) {
        auto encoded = encode_value(value.mutation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("mutation_id", std::move(encoded).value());
    }
    if (!value.origin.is_absent()) {
        auto encoded = encode_value(value.origin);
        if (!encoded) return std::move(encoded).error();
        object.emplace("origin", std::move(encoded).value());
    }
    auto encoded_terminal_id = encode_value(value.terminal_id);
    if (!encoded_terminal_id) return std::move(encoded_terminal_id).error();
    object.emplace("terminal_id", std::move(encoded_terminal_id).value());
    if (!value.terminal_incarnation.is_absent()) {
        auto encoded = encode_value(value.terminal_incarnation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("terminal_incarnation", std::move(encoded).value());
    }
    auto encoded_workspace_key = encode_value(value.workspace_key);
    if (!encoded_workspace_key) return std::move(encoded_workspace_key).error();
    object.emplace("workspace_key", std::move(encoded_workspace_key).value());
    return Json(std::move(object));
}

Result<MoveTerminalRequest> Codec<MoveTerminalRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    MoveTerminalRequest result{};
    const Json* field_expected_generation = value.find("expected_generation");
    if (field_expected_generation) {
        if (field_expected_generation->is_null()) {
            result.expected_generation = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_expected_generation);
            if (!decoded) return std::move(decoded).error();
            result.expected_generation = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_expected_revision = value.find("expected_revision");
    if (!field_expected_revision) {
        field_expected_revision = value.find("expected_terminal_revision");
    }
    if (field_expected_revision) {
        if (field_expected_revision->is_null()) {
            result.expected_revision = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_expected_revision);
            if (!decoded) return std::move(decoded).error();
            result.expected_revision = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    const Json* field_mutation_id = value.find("mutation_id");
    if (field_mutation_id) {
        if (field_mutation_id->is_null()) {
            result.mutation_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_mutation_id);
            if (!decoded) return std::move(decoded).error();
            result.mutation_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_origin = value.find("origin");
    if (field_origin) {
        if (field_origin->is_null()) {
            result.origin = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_origin);
            if (!decoded) return std::move(decoded).error();
            result.origin = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_terminal_id = value.find("terminal_id");
    if (!field_terminal_id) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_id'");
    }
    if (field_terminal_id) {
        auto decoded = decode_value<std::string>(*field_terminal_id);
        if (!decoded) return std::move(decoded).error();
        result.terminal_id = std::move(decoded).value();
    }
    const Json* field_terminal_incarnation = value.find("terminal_incarnation");
    if (field_terminal_incarnation) {
        if (field_terminal_incarnation->is_null()) {
            result.terminal_incarnation = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_terminal_incarnation);
            if (!decoded) return std::move(decoded).error();
            result.terminal_incarnation = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_workspace_key = value.find("workspace_key");
    if (!field_workspace_key) {
        return make_error(ErrorCode::decode, "missing required field 'workspace_key'");
    }
    if (field_workspace_key) {
        auto decoded = decode_value<std::string>(*field_workspace_key);
        if (!decoded) return std::move(decoded).error();
        result.workspace_key = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<MoveWorkspaceRequest>::encode(const MoveWorkspaceRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.expected_generation.is_absent()) {
        auto encoded = encode_value(value.expected_generation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_generation", std::move(encoded).value());
    }
    if (!value.expected_revision.is_absent()) {
        auto encoded = encode_value(value.expected_revision);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_revision", std::move(encoded).value());
    }
    auto encoded_index = encode_value(value.index);
    if (!encoded_index) return std::move(encoded_index).error();
    object.emplace("index", std::move(encoded_index).value());
    if (!value.key.is_absent()) {
        auto encoded = encode_value(value.key);
        if (!encoded) return std::move(encoded).error();
        object.emplace("key", std::move(encoded).value());
    }
    if (!value.mutation_id.is_absent()) {
        auto encoded = encode_value(value.mutation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("mutation_id", std::move(encoded).value());
    }
    if (!value.origin.is_absent()) {
        auto encoded = encode_value(value.origin);
        if (!encoded) return std::move(encoded).error();
        object.emplace("origin", std::move(encoded).value());
    }
    if (!value.workspace.is_absent()) {
        auto encoded = encode_value(value.workspace);
        if (!encoded) return std::move(encoded).error();
        object.emplace("workspace", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<MoveWorkspaceRequest> Codec<MoveWorkspaceRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    MoveWorkspaceRequest result{};
    const Json* field_expected_generation = value.find("expected_generation");
    if (field_expected_generation) {
        if (field_expected_generation->is_null()) {
            result.expected_generation = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_expected_generation);
            if (!decoded) return std::move(decoded).error();
            result.expected_generation = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_expected_revision = value.find("expected_revision");
    if (!field_expected_revision) {
        field_expected_revision = value.find("expected_terminal_revision");
    }
    if (field_expected_revision) {
        if (field_expected_revision->is_null()) {
            result.expected_revision = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_expected_revision);
            if (!decoded) return std::move(decoded).error();
            result.expected_revision = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    const Json* field_index = value.find("index");
    if (!field_index) {
        return make_error(ErrorCode::decode, "missing required field 'index'");
    }
    if (field_index) {
        auto decoded = decode_value<std::uint64_t>(*field_index);
        if (!decoded) return std::move(decoded).error();
        result.index = std::move(decoded).value();
    }
    const Json* field_key = value.find("key");
    if (field_key) {
        if (field_key->is_null()) {
            result.key = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_key);
            if (!decoded) return std::move(decoded).error();
            result.key = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_mutation_id = value.find("mutation_id");
    if (field_mutation_id) {
        if (field_mutation_id->is_null()) {
            result.mutation_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_mutation_id);
            if (!decoded) return std::move(decoded).error();
            result.mutation_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_origin = value.find("origin");
    if (field_origin) {
        if (field_origin->is_null()) {
            result.origin = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_origin);
            if (!decoded) return std::move(decoded).error();
            result.origin = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_workspace = value.find("workspace");
    if (field_workspace) {
        if (field_workspace->is_null()) {
            result.workspace = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_workspace);
            if (!decoded) return std::move(decoded).error();
            result.workspace = Field<Id>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<NewBrowserTabRequest>::encode(const NewBrowserTabRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.cols.is_absent()) {
        auto encoded = encode_value(value.cols);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cols", std::move(encoded).value());
    }
    if (!value.pane.is_absent()) {
        auto encoded = encode_value(value.pane);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pane", std::move(encoded).value());
    }
    if (!value.rows.is_absent()) {
        auto encoded = encode_value(value.rows);
        if (!encoded) return std::move(encoded).error();
        object.emplace("rows", std::move(encoded).value());
    }
    auto encoded_url = encode_value(value.url);
    if (!encoded_url) return std::move(encoded_url).error();
    object.emplace("url", std::move(encoded_url).value());
    return Json(std::move(object));
}

Result<NewBrowserTabRequest> Codec<NewBrowserTabRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    NewBrowserTabRequest result{};
    const Json* field_cols = value.find("cols");
    if (field_cols) {
        if (field_cols->is_null()) {
            result.cols = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_cols);
            if (!decoded) return std::move(decoded).error();
            result.cols = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_pane = value.find("pane");
    if (field_pane) {
        if (field_pane->is_null()) {
            result.pane = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_pane);
            if (!decoded) return std::move(decoded).error();
            result.pane = Field<Id>(std::move(decoded).value());
        }
    }
    const Json* field_rows = value.find("rows");
    if (field_rows) {
        if (field_rows->is_null()) {
            result.rows = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_rows);
            if (!decoded) return std::move(decoded).error();
            result.rows = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_url = value.find("url");
    if (!field_url) {
        return make_error(ErrorCode::decode, "missing required field 'url'");
    }
    if (field_url) {
        auto decoded = decode_value<std::string>(*field_url);
        if (!decoded) return std::move(decoded).error();
        result.url = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<NewPaneRequest>::encode(const NewPaneRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.cols.is_absent()) {
        auto encoded = encode_value(value.cols);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cols", std::move(encoded).value());
    }
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    if (!value.rows.is_absent()) {
        auto encoded = encode_value(value.rows);
        if (!encoded) return std::move(encoded).error();
        object.emplace("rows", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<NewPaneRequest> Codec<NewPaneRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    NewPaneRequest result{};
    const Json* field_cols = value.find("cols");
    if (field_cols) {
        if (field_cols->is_null()) {
            result.cols = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_cols);
            if (!decoded) return std::move(decoded).error();
            result.cols = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (field_rows) {
        if (field_rows->is_null()) {
            result.rows = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_rows);
            if (!decoded) return std::move(decoded).error();
            result.rows = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<NewPaneRightRequest>::encode(const NewPaneRightRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.cols.is_absent()) {
        auto encoded = encode_value(value.cols);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cols", std::move(encoded).value());
    }
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    if (!value.rows.is_absent()) {
        auto encoded = encode_value(value.rows);
        if (!encoded) return std::move(encoded).error();
        object.emplace("rows", std::move(encoded).value());
    }
    if (!value.width.is_absent()) {
        auto encoded = encode_value(value.width);
        if (!encoded) return std::move(encoded).error();
        object.emplace("width", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<NewPaneRightRequest> Codec<NewPaneRightRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    NewPaneRightRequest result{};
    const Json* field_cols = value.find("cols");
    if (field_cols) {
        if (field_cols->is_null()) {
            result.cols = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_cols);
            if (!decoded) return std::move(decoded).error();
            result.cols = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (field_rows) {
        if (field_rows->is_null()) {
            result.rows = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_rows);
            if (!decoded) return std::move(decoded).error();
            result.rows = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_width = value.find("width");
    if (field_width) {
        if (field_width->is_null()) {
            result.width = Field<float>::null();
        } else {
            auto decoded = decode_value<float>(*field_width);
            if (!decoded) return std::move(decoded).error();
            result.width = Field<float>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<NewScreenRequest>::encode(const NewScreenRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.cols.is_absent()) {
        auto encoded = encode_value(value.cols);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cols", std::move(encoded).value());
    }
    if (!value.rows.is_absent()) {
        auto encoded = encode_value(value.rows);
        if (!encoded) return std::move(encoded).error();
        object.emplace("rows", std::move(encoded).value());
    }
    if (!value.workspace.is_absent()) {
        auto encoded = encode_value(value.workspace);
        if (!encoded) return std::move(encoded).error();
        object.emplace("workspace", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<NewScreenRequest> Codec<NewScreenRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    NewScreenRequest result{};
    const Json* field_cols = value.find("cols");
    if (field_cols) {
        if (field_cols->is_null()) {
            result.cols = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_cols);
            if (!decoded) return std::move(decoded).error();
            result.cols = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_rows = value.find("rows");
    if (field_rows) {
        if (field_rows->is_null()) {
            result.rows = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_rows);
            if (!decoded) return std::move(decoded).error();
            result.rows = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_workspace = value.find("workspace");
    if (field_workspace) {
        if (field_workspace->is_null()) {
            result.workspace = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_workspace);
            if (!decoded) return std::move(decoded).error();
            result.workspace = Field<Id>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<NewTabRequest>::encode(const NewTabRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.cols.is_absent()) {
        auto encoded = encode_value(value.cols);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cols", std::move(encoded).value());
    }
    if (!value.cwd.is_absent()) {
        auto encoded = encode_value(value.cwd);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cwd", std::move(encoded).value());
    }
    if (!value.pane.is_absent()) {
        auto encoded = encode_value(value.pane);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pane", std::move(encoded).value());
    }
    if (!value.rows.is_absent()) {
        auto encoded = encode_value(value.rows);
        if (!encoded) return std::move(encoded).error();
        object.emplace("rows", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<NewTabRequest> Codec<NewTabRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    NewTabRequest result{};
    const Json* field_cols = value.find("cols");
    if (field_cols) {
        if (field_cols->is_null()) {
            result.cols = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_cols);
            if (!decoded) return std::move(decoded).error();
            result.cols = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_cwd = value.find("cwd");
    if (field_cwd) {
        if (field_cwd->is_null()) {
            result.cwd = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_cwd);
            if (!decoded) return std::move(decoded).error();
            result.cwd = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_pane = value.find("pane");
    if (field_pane) {
        if (field_pane->is_null()) {
            result.pane = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_pane);
            if (!decoded) return std::move(decoded).error();
            result.pane = Field<Id>(std::move(decoded).value());
        }
    }
    const Json* field_rows = value.find("rows");
    if (field_rows) {
        if (field_rows->is_null()) {
            result.rows = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_rows);
            if (!decoded) return std::move(decoded).error();
            result.rows = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<NewWorkspaceRequest>::encode(const NewWorkspaceRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.cols.is_absent()) {
        auto encoded = encode_value(value.cols);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cols", std::move(encoded).value());
    }
    if (!value.name.is_absent()) {
        auto encoded = encode_value(value.name);
        if (!encoded) return std::move(encoded).error();
        object.emplace("name", std::move(encoded).value());
    }
    if (!value.rows.is_absent()) {
        auto encoded = encode_value(value.rows);
        if (!encoded) return std::move(encoded).error();
        object.emplace("rows", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<NewWorkspaceRequest> Codec<NewWorkspaceRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    NewWorkspaceRequest result{};
    const Json* field_cols = value.find("cols");
    if (field_cols) {
        if (field_cols->is_null()) {
            result.cols = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_cols);
            if (!decoded) return std::move(decoded).error();
            result.cols = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_name = value.find("name");
    if (field_name) {
        if (field_name->is_null()) {
            result.name = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_name);
            if (!decoded) return std::move(decoded).error();
            result.name = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_rows = value.find("rows");
    if (field_rows) {
        if (field_rows->is_null()) {
            result.rows = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_rows);
            if (!decoded) return std::move(decoded).error();
            result.rows = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<NotifyRequest>::encode(const NotifyRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_body = encode_value(value.body);
    if (!encoded_body) return std::move(encoded_body).error();
    object.emplace("body", std::move(encoded_body).value());
    if (!value.level.is_absent()) {
        auto encoded = encode_value(value.level);
        if (!encoded) return std::move(encoded).error();
        object.emplace("level", std::move(encoded).value());
    }
    if (!value.surface.is_absent()) {
        auto encoded = encode_value(value.surface);
        if (!encoded) return std::move(encoded).error();
        object.emplace("surface", std::move(encoded).value());
    }
    auto encoded_title = encode_value(value.title);
    if (!encoded_title) return std::move(encoded_title).error();
    object.emplace("title", std::move(encoded_title).value());
    return Json(std::move(object));
}

Result<NotifyRequest> Codec<NotifyRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    NotifyRequest result{};
    const Json* field_body = value.find("body");
    if (!field_body) {
        return make_error(ErrorCode::decode, "missing required field 'body'");
    }
    if (field_body) {
        auto decoded = decode_value<std::string>(*field_body);
        if (!decoded) return std::move(decoded).error();
        result.body = std::move(decoded).value();
    }
    const Json* field_level = value.find("level");
    if (field_level) {
        if (field_level->is_null()) {
            result.level = Field<NotificationLevel>::null();
        } else {
            auto decoded = decode_value<NotificationLevel>(*field_level);
            if (!decoded) return std::move(decoded).error();
            result.level = Field<NotificationLevel>(std::move(decoded).value());
        }
    }
    const Json* field_surface = value.find("surface");
    if (field_surface) {
        if (field_surface->is_null()) {
            result.surface = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_surface);
            if (!decoded) return std::move(decoded).error();
            result.surface = Field<Id>(std::move(decoded).value());
        }
    }
    const Json* field_title = value.find("title");
    if (!field_title) {
        return make_error(ErrorCode::decode, "missing required field 'title'");
    }
    if (field_title) {
        auto decoded = decode_value<std::string>(*field_title);
        if (!decoded) return std::move(decoded).error();
        result.title = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<PairingResponseRequest>::encode(const PairingResponseRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_approve = encode_value(value.approve);
    if (!encoded_approve) return std::move(encoded_approve).error();
    object.emplace("approve", std::move(encoded_approve).value());
    auto encoded_request = encode_value(value.request);
    if (!encoded_request) return std::move(encoded_request).error();
    object.emplace("request", std::move(encoded_request).value());
    return Json(std::move(object));
}

Result<PairingResponseRequest> Codec<PairingResponseRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    PairingResponseRequest result{};
    const Json* field_approve = value.find("approve");
    if (!field_approve) {
        return make_error(ErrorCode::decode, "missing required field 'approve'");
    }
    if (field_approve) {
        auto decoded = decode_value<bool>(*field_approve);
        if (!decoded) return std::move(decoded).error();
        result.approve = std::move(decoded).value();
    }
    const Json* field_request = value.find("request");
    if (!field_request) {
        return make_error(ErrorCode::decode, "missing required field 'request'");
    }
    if (field_request) {
        auto decoded = decode_value<std::uint64_t>(*field_request);
        if (!decoded) return std::move(decoded).error();
        result.request = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<PaneNeighborRequest>::encode(const PaneNeighborRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_dir = encode_value(value.dir);
    if (!encoded_dir) return std::move(encoded_dir).error();
    object.emplace("dir", std::move(encoded_dir).value());
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    return Json(std::move(object));
}

Result<PaneNeighborRequest> Codec<PaneNeighborRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    PaneNeighborRequest result{};
    const Json* field_dir = value.find("dir");
    if (!field_dir) {
        return make_error(ErrorCode::decode, "missing required field 'dir'");
    }
    if (field_dir) {
        auto decoded = decode_value<PaneDirection>(*field_dir);
        if (!decoded) return std::move(decoded).error();
        result.dir = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<PingRequest>::encode(const PingRequest& value) {
    (void)value;
    Json::Object object;
    return Json(std::move(object));
}

Result<PingRequest> Codec<PingRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    PingRequest result{};
    return result;
}

Result<Json> Codec<ProcessInfoRequest>::encode(const ProcessInfoRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<ProcessInfoRequest> Codec<ProcessInfoRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ProcessInfoRequest result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<PutFrontendProjectionRequest>::encode(const PutFrontendProjectionRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.expected_generation.is_absent()) {
        auto encoded = encode_value(value.expected_generation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_generation", std::move(encoded).value());
    }
    if (!value.expected_projection_revision.is_absent()) {
        auto encoded = encode_value(value.expected_projection_revision);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_projection_revision", std::move(encoded).value());
    }
    if (!value.expected_revision.is_absent()) {
        auto encoded = encode_value(value.expected_revision);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_revision", std::move(encoded).value());
    }
    auto encoded_frontend = encode_value(value.frontend);
    if (!encoded_frontend) return std::move(encoded_frontend).error();
    object.emplace("frontend", std::move(encoded_frontend).value());
    if (!value.mutation_id.is_absent()) {
        auto encoded = encode_value(value.mutation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("mutation_id", std::move(encoded).value());
    }
    if (!value.origin.is_absent()) {
        auto encoded = encode_value(value.origin);
        if (!encoded) return std::move(encoded).error();
        object.emplace("origin", std::move(encoded).value());
    }
    if (value.projection) {
        auto encoded = encode_value(*value.projection);
        if (!encoded) return std::move(encoded).error();
        object.emplace("projection", std::move(encoded).value());
    } else {
        object.emplace("projection", Json(nullptr));
    }
    auto encoded_schema_version = encode_value(value.schema_version);
    if (!encoded_schema_version) return std::move(encoded_schema_version).error();
    object.emplace("schema_version", std::move(encoded_schema_version).value());
    auto encoded_scope = encode_value(value.scope);
    if (!encoded_scope) return std::move(encoded_scope).error();
    object.emplace("scope", std::move(encoded_scope).value());
    auto encoded_subject_key = encode_value(value.subject_key);
    if (!encoded_subject_key) return std::move(encoded_subject_key).error();
    object.emplace("subject_key", std::move(encoded_subject_key).value());
    return Json(std::move(object));
}

Result<PutFrontendProjectionRequest> Codec<PutFrontendProjectionRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    PutFrontendProjectionRequest result{};
    const Json* field_expected_generation = value.find("expected_generation");
    if (field_expected_generation) {
        if (field_expected_generation->is_null()) {
            result.expected_generation = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_expected_generation);
            if (!decoded) return std::move(decoded).error();
            result.expected_generation = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_expected_projection_revision = value.find("expected_projection_revision");
    if (field_expected_projection_revision) {
        if (field_expected_projection_revision->is_null()) {
            result.expected_projection_revision = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_expected_projection_revision);
            if (!decoded) return std::move(decoded).error();
            result.expected_projection_revision = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    const Json* field_expected_revision = value.find("expected_revision");
    if (!field_expected_revision) {
        field_expected_revision = value.find("expected_terminal_revision");
    }
    if (field_expected_revision) {
        if (field_expected_revision->is_null()) {
            result.expected_revision = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_expected_revision);
            if (!decoded) return std::move(decoded).error();
            result.expected_revision = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    const Json* field_frontend = value.find("frontend");
    if (!field_frontend) {
        return make_error(ErrorCode::decode, "missing required field 'frontend'");
    }
    if (field_frontend) {
        auto decoded = decode_value<std::string>(*field_frontend);
        if (!decoded) return std::move(decoded).error();
        result.frontend = std::move(decoded).value();
    }
    const Json* field_mutation_id = value.find("mutation_id");
    if (field_mutation_id) {
        if (field_mutation_id->is_null()) {
            result.mutation_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_mutation_id);
            if (!decoded) return std::move(decoded).error();
            result.mutation_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_origin = value.find("origin");
    if (field_origin) {
        if (field_origin->is_null()) {
            result.origin = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_origin);
            if (!decoded) return std::move(decoded).error();
            result.origin = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_projection = value.find("projection");
    if (!field_projection) {
        return make_error(ErrorCode::decode, "missing required field 'projection'");
    }
    if (field_projection) {
        if (field_projection->is_null()) {
            result.projection.reset();
        } else {
            auto decoded = decode_value<JsonValue>(*field_projection);
            if (!decoded) return std::move(decoded).error();
            result.projection = std::move(decoded).value();
        }
    }
    const Json* field_schema_version = value.find("schema_version");
    if (!field_schema_version) {
        return make_error(ErrorCode::decode, "missing required field 'schema_version'");
    }
    if (field_schema_version) {
        auto decoded = decode_value<std::uint32_t>(*field_schema_version);
        if (!decoded) return std::move(decoded).error();
        result.schema_version = std::move(decoded).value();
    }
    const Json* field_scope = value.find("scope");
    if (!field_scope) {
        return make_error(ErrorCode::decode, "missing required field 'scope'");
    }
    if (field_scope) {
        auto decoded = decode_value<std::string>(*field_scope);
        if (!decoded) return std::move(decoded).error();
        result.scope = std::move(decoded).value();
    }
    const Json* field_subject_key = value.find("subject_key");
    if (!field_subject_key) {
        return make_error(ErrorCode::decode, "missing required field 'subject_key'");
    }
    if (field_subject_key) {
        auto decoded = decode_value<std::string>(*field_subject_key);
        if (!decoded) return std::move(decoded).error();
        result.subject_key = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ReadScreenRequest>::encode(const ReadScreenRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<ReadScreenRequest> Codec<ReadScreenRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ReadScreenRequest result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ReadScrollbackRequest>::encode(const ReadScrollbackRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_count = encode_value(value.count);
    if (!encoded_count) return std::move(encoded_count).error();
    object.emplace("count", std::move(encoded_count).value());
    auto encoded_start = encode_value(value.start);
    if (!encoded_start) return std::move(encoded_start).error();
    object.emplace("start", std::move(encoded_start).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<ReadScrollbackRequest> Codec<ReadScrollbackRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ReadScrollbackRequest result{};
    const Json* field_count = value.find("count");
    if (!field_count) {
        return make_error(ErrorCode::decode, "missing required field 'count'");
    }
    if (field_count) {
        auto decoded = decode_value<std::uint32_t>(*field_count);
        if (!decoded) return std::move(decoded).error();
        result.count = std::move(decoded).value();
    }
    const Json* field_start = value.find("start");
    if (!field_start) {
        return make_error(ErrorCode::decode, "missing required field 'start'");
    }
    if (field_start) {
        auto decoded = decode_value<std::uint32_t>(*field_start);
        if (!decoded) return std::move(decoded).error();
        result.start = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<RegisterBrowserProviderRequest>::encode(const RegisterBrowserProviderRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_authentication = encode_value(value.authentication);
    if (!encoded_authentication) return std::move(encoded_authentication).error();
    object.emplace("authentication", std::move(encoded_authentication).value());
    if (!value.bearer_token.is_absent()) {
        auto encoded = encode_value(value.bearer_token);
        if (!encoded) return std::move(encoded).error();
        object.emplace("bearer_token", std::move(encoded).value());
    }
    auto encoded_endpoint = encode_value(value.endpoint);
    if (!encoded_endpoint) return std::move(encoded_endpoint).error();
    object.emplace("endpoint", std::move(encoded_endpoint).value());
    auto encoded_provider_id = encode_value(value.provider_id);
    if (!encoded_provider_id) return std::move(encoded_provider_id).error();
    object.emplace("provider_id", std::move(encoded_provider_id).value());
    auto encoded_targets = encode_value(value.targets);
    if (!encoded_targets) return std::move(encoded_targets).error();
    object.emplace("targets", std::move(encoded_targets).value());
    return Json(std::move(object));
}

Result<RegisterBrowserProviderRequest> Codec<RegisterBrowserProviderRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RegisterBrowserProviderRequest result{};
    const Json* field_authentication = value.find("authentication");
    if (!field_authentication) {
        return make_error(ErrorCode::decode, "missing required field 'authentication'");
    }
    if (field_authentication) {
        auto decoded = decode_value<BrowserProviderAuthentication>(*field_authentication);
        if (!decoded) return std::move(decoded).error();
        result.authentication = std::move(decoded).value();
    }
    const Json* field_bearer_token = value.find("bearer_token");
    if (field_bearer_token) {
        if (field_bearer_token->is_null()) {
            result.bearer_token = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_bearer_token);
            if (!decoded) return std::move(decoded).error();
            result.bearer_token = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_endpoint = value.find("endpoint");
    if (!field_endpoint) {
        return make_error(ErrorCode::decode, "missing required field 'endpoint'");
    }
    if (field_endpoint) {
        auto decoded = decode_value<std::string>(*field_endpoint);
        if (!decoded) return std::move(decoded).error();
        result.endpoint = std::move(decoded).value();
    }
    const Json* field_provider_id = value.find("provider_id");
    if (!field_provider_id) {
        return make_error(ErrorCode::decode, "missing required field 'provider_id'");
    }
    if (field_provider_id) {
        auto decoded = decode_value<std::string>(*field_provider_id);
        if (!decoded) return std::move(decoded).error();
        result.provider_id = std::move(decoded).value();
    }
    const Json* field_targets = value.find("targets");
    if (!field_targets) {
        return make_error(ErrorCode::decode, "missing required field 'targets'");
    }
    if (field_targets) {
        auto decoded = decode_value<std::vector<BrowserProviderTarget>>(*field_targets);
        if (!decoded) return std::move(decoded).error();
        result.targets = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ReleaseAttachedViewSizeRequest>::encode(const ReleaseAttachedViewSizeRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_lease = encode_value(value.lease);
    if (!encoded_lease) return std::move(encoded_lease).error();
    object.emplace("lease", std::move(encoded_lease).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<ReleaseAttachedViewSizeRequest> Codec<ReleaseAttachedViewSizeRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ReleaseAttachedViewSizeRequest result{};
    const Json* field_lease = value.find("lease");
    if (!field_lease) {
        return make_error(ErrorCode::decode, "missing required field 'lease'");
    }
    if (field_lease) {
        auto decoded = decode_value<std::string>(*field_lease);
        if (!decoded) return std::move(decoded).error();
        result.lease = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ReleaseSurfaceSizeRequest>::encode(const ReleaseSurfaceSizeRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<ReleaseSurfaceSizeRequest> Codec<ReleaseSurfaceSizeRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ReleaseSurfaceSizeRequest result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ReloadConfigRequest>::encode(const ReloadConfigRequest& value) {
    (void)value;
    Json::Object object;
    return Json(std::move(object));
}

Result<ReloadConfigRequest> Codec<ReloadConfigRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ReloadConfigRequest result{};
    return result;
}

Result<Json> Codec<ReloadConfigResult>::encode(const ReloadConfigResult& value) {
    (void)value;
    Json::Object object;
    if (value.path) {
        auto encoded = encode_value(*value.path);
        if (!encoded) return std::move(encoded).error();
        object.emplace("path", std::move(encoded).value());
    } else {
        object.emplace("path", Json(nullptr));
    }
    object.emplace("reloaded", Json(true));
    return Json(std::move(object));
}

Result<ReloadConfigResult> Codec<ReloadConfigResult>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ReloadConfigResult result{};
    const Json* field_path = value.find("path");
    if (!field_path) {
        return make_error(ErrorCode::decode, "missing required field 'path'");
    }
    if (field_path) {
        if (field_path->is_null()) {
            result.path.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_path);
            if (!decoded) return std::move(decoded).error();
            result.path = std::move(decoded).value();
        }
    }
    const Json* field_reloaded = value.find("reloaded");
    if (!field_reloaded) {
        return make_error(ErrorCode::decode, "missing required field 'reloaded'");
    }
    if (field_reloaded) {
        if (*field_reloaded != Json(true)) {
            return make_error(ErrorCode::decode, "field 'reloaded' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<RenamePaneRequest>::encode(const RenamePaneRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_name = encode_value(value.name);
    if (!encoded_name) return std::move(encoded_name).error();
    object.emplace("name", std::move(encoded_name).value());
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    return Json(std::move(object));
}

Result<RenamePaneRequest> Codec<RenamePaneRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RenamePaneRequest result{};
    const Json* field_name = value.find("name");
    if (!field_name) {
        return make_error(ErrorCode::decode, "missing required field 'name'");
    }
    if (field_name) {
        auto decoded = decode_value<std::string>(*field_name);
        if (!decoded) return std::move(decoded).error();
        result.name = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<RenameProviderManagedWorkspaceRequest>::encode(const RenameProviderManagedWorkspaceRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_authority = encode_value(value.authority);
    if (!encoded_authority) return std::move(encoded_authority).error();
    object.emplace("authority", std::move(encoded_authority).value());
    auto encoded_key = encode_value(value.key);
    if (!encoded_key) return std::move(encoded_key).error();
    object.emplace("key", std::move(encoded_key).value());
    auto encoded_name = encode_value(value.name);
    if (!encoded_name) return std::move(encoded_name).error();
    object.emplace("name", std::move(encoded_name).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    return Json(std::move(object));
}

Result<RenameProviderManagedWorkspaceRequest> Codec<RenameProviderManagedWorkspaceRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RenameProviderManagedWorkspaceRequest result{};
    const Json* field_authority = value.find("authority");
    if (!field_authority) {
        return make_error(ErrorCode::decode, "missing required field 'authority'");
    }
    if (field_authority) {
        auto decoded = decode_value<std::string>(*field_authority);
        if (!decoded) return std::move(decoded).error();
        result.authority = std::move(decoded).value();
    }
    const Json* field_key = value.find("key");
    if (!field_key) {
        return make_error(ErrorCode::decode, "missing required field 'key'");
    }
    if (field_key) {
        auto decoded = decode_value<std::string>(*field_key);
        if (!decoded) return std::move(decoded).error();
        result.key = std::move(decoded).value();
    }
    const Json* field_name = value.find("name");
    if (!field_name) {
        return make_error(ErrorCode::decode, "missing required field 'name'");
    }
    if (field_name) {
        auto decoded = decode_value<std::string>(*field_name);
        if (!decoded) return std::move(decoded).error();
        result.name = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<RenameScreenRequest>::encode(const RenameScreenRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_name = encode_value(value.name);
    if (!encoded_name) return std::move(encoded_name).error();
    object.emplace("name", std::move(encoded_name).value());
    auto encoded_screen = encode_value(value.screen);
    if (!encoded_screen) return std::move(encoded_screen).error();
    object.emplace("screen", std::move(encoded_screen).value());
    return Json(std::move(object));
}

Result<RenameScreenRequest> Codec<RenameScreenRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RenameScreenRequest result{};
    const Json* field_name = value.find("name");
    if (!field_name) {
        return make_error(ErrorCode::decode, "missing required field 'name'");
    }
    if (field_name) {
        auto decoded = decode_value<std::string>(*field_name);
        if (!decoded) return std::move(decoded).error();
        result.name = std::move(decoded).value();
    }
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        auto decoded = decode_value<Id>(*field_screen);
        if (!decoded) return std::move(decoded).error();
        result.screen = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<RenameSurfaceRequest>::encode(const RenameSurfaceRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_name = encode_value(value.name);
    if (!encoded_name) return std::move(encoded_name).error();
    object.emplace("name", std::move(encoded_name).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<RenameSurfaceRequest> Codec<RenameSurfaceRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RenameSurfaceRequest result{};
    const Json* field_name = value.find("name");
    if (!field_name) {
        return make_error(ErrorCode::decode, "missing required field 'name'");
    }
    if (field_name) {
        auto decoded = decode_value<std::string>(*field_name);
        if (!decoded) return std::move(decoded).error();
        result.name = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<RenameWorkspaceRequest>::encode(const RenameWorkspaceRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.expected_generation.is_absent()) {
        auto encoded = encode_value(value.expected_generation);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_generation", std::move(encoded).value());
    }
    if (!value.expected_revision.is_absent()) {
        auto encoded = encode_value(value.expected_revision);
        if (!encoded) return std::move(encoded).error();
        object.emplace("expected_revision", std::move(encoded).value());
    }
    if (!value.key.is_absent()) {
        auto encoded = encode_value(value.key);
        if (!encoded) return std::move(encoded).error();
        object.emplace("key", std::move(encoded).value());
    }
    if (!value.mutation_id.is_absent()) {
        auto encoded = encode_value(value.mutation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("mutation_id", std::move(encoded).value());
    }
    auto encoded_name = encode_value(value.name);
    if (!encoded_name) return std::move(encoded_name).error();
    object.emplace("name", std::move(encoded_name).value());
    if (!value.origin.is_absent()) {
        auto encoded = encode_value(value.origin);
        if (!encoded) return std::move(encoded).error();
        object.emplace("origin", std::move(encoded).value());
    }
    if (!value.workspace.is_absent()) {
        auto encoded = encode_value(value.workspace);
        if (!encoded) return std::move(encoded).error();
        object.emplace("workspace", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<RenameWorkspaceRequest> Codec<RenameWorkspaceRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RenameWorkspaceRequest result{};
    const Json* field_expected_generation = value.find("expected_generation");
    if (field_expected_generation) {
        if (field_expected_generation->is_null()) {
            result.expected_generation = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_expected_generation);
            if (!decoded) return std::move(decoded).error();
            result.expected_generation = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_expected_revision = value.find("expected_revision");
    if (!field_expected_revision) {
        field_expected_revision = value.find("expected_terminal_revision");
    }
    if (field_expected_revision) {
        if (field_expected_revision->is_null()) {
            result.expected_revision = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_expected_revision);
            if (!decoded) return std::move(decoded).error();
            result.expected_revision = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    const Json* field_key = value.find("key");
    if (field_key) {
        if (field_key->is_null()) {
            result.key = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_key);
            if (!decoded) return std::move(decoded).error();
            result.key = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_mutation_id = value.find("mutation_id");
    if (field_mutation_id) {
        if (field_mutation_id->is_null()) {
            result.mutation_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_mutation_id);
            if (!decoded) return std::move(decoded).error();
            result.mutation_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_name = value.find("name");
    if (!field_name) {
        return make_error(ErrorCode::decode, "missing required field 'name'");
    }
    if (field_name) {
        auto decoded = decode_value<std::string>(*field_name);
        if (!decoded) return std::move(decoded).error();
        result.name = std::move(decoded).value();
    }
    const Json* field_origin = value.find("origin");
    if (field_origin) {
        if (field_origin->is_null()) {
            result.origin = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_origin);
            if (!decoded) return std::move(decoded).error();
            result.origin = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_workspace = value.find("workspace");
    if (field_workspace) {
        if (field_workspace->is_null()) {
            result.workspace = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_workspace);
            if (!decoded) return std::move(decoded).error();
            result.workspace = Field<Id>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<ReportAgentRequest>::encode(const ReportAgentRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.session.is_absent()) {
        auto encoded = encode_value(value.session);
        if (!encoded) return std::move(encoded).error();
        object.emplace("session", std::move(encoded).value());
    }
    auto encoded_source = encode_value(value.source);
    if (!encoded_source) return std::move(encoded_source).error();
    object.emplace("source", std::move(encoded_source).value());
    auto encoded_state = encode_value(value.state);
    if (!encoded_state) return std::move(encoded_state).error();
    object.emplace("state", std::move(encoded_state).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<ReportAgentRequest> Codec<ReportAgentRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ReportAgentRequest result{};
    const Json* field_session = value.find("session");
    if (field_session) {
        if (field_session->is_null()) {
            result.session = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_session);
            if (!decoded) return std::move(decoded).error();
            result.session = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_source = value.find("source");
    if (!field_source) {
        return make_error(ErrorCode::decode, "missing required field 'source'");
    }
    if (field_source) {
        auto decoded = decode_value<AgentReportSource>(*field_source);
        if (!decoded) return std::move(decoded).error();
        result.source = std::move(decoded).value();
    }
    const Json* field_state = value.find("state");
    if (!field_state) {
        return make_error(ErrorCode::decode, "missing required field 'state'");
    }
    if (field_state) {
        auto decoded = decode_value<AgentState>(*field_state);
        if (!decoded) return std::move(decoded).error();
        result.state = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ReportFocusRequest>::encode(const ReportFocusRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_client_id = encode_value(value.client_id);
    if (!encoded_client_id) return std::move(encoded_client_id).error();
    object.emplace("client_id", std::move(encoded_client_id).value());
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    if (!value.tab.is_absent()) {
        auto encoded = encode_value(value.tab);
        if (!encoded) return std::move(encoded).error();
        object.emplace("tab", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<ReportFocusRequest> Codec<ReportFocusRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ReportFocusRequest result{};
    const Json* field_client_id = value.find("client_id");
    if (!field_client_id) {
        return make_error(ErrorCode::decode, "missing required field 'client_id'");
    }
    if (field_client_id) {
        auto decoded = decode_value<std::string>(*field_client_id);
        if (!decoded) return std::move(decoded).error();
        result.client_id = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_tab = value.find("tab");
    if (field_tab) {
        if (field_tab->is_null()) {
            result.tab = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_tab);
            if (!decoded) return std::move(decoded).error();
            result.tab = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<ResizeAttachedViewRequest>::encode(const ResizeAttachedViewRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_cols = encode_value(value.cols);
    if (!encoded_cols) return std::move(encoded_cols).error();
    object.emplace("cols", std::move(encoded_cols).value());
    auto encoded_lease = encode_value(value.lease);
    if (!encoded_lease) return std::move(encoded_lease).error();
    object.emplace("lease", std::move(encoded_lease).value());
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<ResizeAttachedViewRequest> Codec<ResizeAttachedViewRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ResizeAttachedViewRequest result{};
    const Json* field_cols = value.find("cols");
    if (!field_cols) {
        return make_error(ErrorCode::decode, "missing required field 'cols'");
    }
    if (field_cols) {
        auto decoded = decode_value<std::uint16_t>(*field_cols);
        if (!decoded) return std::move(decoded).error();
        result.cols = std::move(decoded).value();
    }
    const Json* field_lease = value.find("lease");
    if (!field_lease) {
        return make_error(ErrorCode::decode, "missing required field 'lease'");
    }
    if (field_lease) {
        auto decoded = decode_value<std::string>(*field_lease);
        if (!decoded) return std::move(decoded).error();
        result.lease = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::uint16_t>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ResizeSurfaceRequest>::encode(const ResizeSurfaceRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_cols = encode_value(value.cols);
    if (!encoded_cols) return std::move(encoded_cols).error();
    object.emplace("cols", std::move(encoded_cols).value());
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<ResizeSurfaceRequest> Codec<ResizeSurfaceRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ResizeSurfaceRequest result{};
    const Json* field_cols = value.find("cols");
    if (!field_cols) {
        return make_error(ErrorCode::decode, "missing required field 'cols'");
    }
    if (field_cols) {
        auto decoded = decode_value<std::uint16_t>(*field_cols);
        if (!decoded) return std::move(decoded).error();
        result.cols = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::uint16_t>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ResolveTerminalRequest>::encode(const ResolveTerminalRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_terminal_id = encode_value(value.terminal_id);
    if (!encoded_terminal_id) return std::move(encoded_terminal_id).error();
    object.emplace("terminal_id", std::move(encoded_terminal_id).value());
    return Json(std::move(object));
}

Result<ResolveTerminalRequest> Codec<ResolveTerminalRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ResolveTerminalRequest result{};
    const Json* field_terminal_id = value.find("terminal_id");
    if (!field_terminal_id) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_id'");
    }
    if (field_terminal_id) {
        auto decoded = decode_value<std::string>(*field_terminal_id);
        if (!decoded) return std::move(decoded).error();
        result.terminal_id = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<RunRequest>::encode(const RunRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.argv.is_absent()) {
        auto encoded = encode_value(value.argv);
        if (!encoded) return std::move(encoded).error();
        object.emplace("argv", std::move(encoded).value());
    }
    if (!value.cols.is_absent()) {
        auto encoded = encode_value(value.cols);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cols", std::move(encoded).value());
    }
    if (!value.command.is_absent()) {
        auto encoded = encode_value(value.command);
        if (!encoded) return std::move(encoded).error();
        object.emplace("command", std::move(encoded).value());
    }
    if (!value.cwd.is_absent()) {
        auto encoded = encode_value(value.cwd);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cwd", std::move(encoded).value());
    }
    if (!value.key.is_absent()) {
        auto encoded = encode_value(value.key);
        if (!encoded) return std::move(encoded).error();
        object.emplace("key", std::move(encoded).value());
    }
    if (!value.name.is_absent()) {
        auto encoded = encode_value(value.name);
        if (!encoded) return std::move(encoded).error();
        object.emplace("name", std::move(encoded).value());
    }
    if (value.new_workspace) {
        auto encoded = encode_value(*value.new_workspace);
        if (!encoded) return std::move(encoded).error();
        object.emplace("new_workspace", std::move(encoded).value());
    }
    if (!value.pane.is_absent()) {
        auto encoded = encode_value(value.pane);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pane", std::move(encoded).value());
    }
    if (!value.rows.is_absent()) {
        auto encoded = encode_value(value.rows);
        if (!encoded) return std::move(encoded).error();
        object.emplace("rows", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<RunRequest> Codec<RunRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RunRequest result{};
    const Json* field_argv = value.find("argv");
    if (field_argv) {
        if (field_argv->is_null()) {
            result.argv = Field<std::vector<std::string>>::null();
        } else {
            auto decoded = decode_value<std::vector<std::string>>(*field_argv);
            if (!decoded) return std::move(decoded).error();
            result.argv = Field<std::vector<std::string>>(std::move(decoded).value());
        }
    }
    const Json* field_cols = value.find("cols");
    if (field_cols) {
        if (field_cols->is_null()) {
            result.cols = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_cols);
            if (!decoded) return std::move(decoded).error();
            result.cols = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_command = value.find("command");
    if (field_command) {
        if (field_command->is_null()) {
            result.command = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_command);
            if (!decoded) return std::move(decoded).error();
            result.command = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_cwd = value.find("cwd");
    if (field_cwd) {
        if (field_cwd->is_null()) {
            result.cwd = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_cwd);
            if (!decoded) return std::move(decoded).error();
            result.cwd = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_key = value.find("key");
    if (field_key) {
        if (field_key->is_null()) {
            result.key = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_key);
            if (!decoded) return std::move(decoded).error();
            result.key = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_name = value.find("name");
    if (field_name) {
        if (field_name->is_null()) {
            result.name = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_name);
            if (!decoded) return std::move(decoded).error();
            result.name = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_new_workspace = value.find("new_workspace");
    if (field_new_workspace) {
        auto decoded = decode_value<bool>(*field_new_workspace);
        if (!decoded) return std::move(decoded).error();
        result.new_workspace = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (field_pane) {
        if (field_pane->is_null()) {
            result.pane = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_pane);
            if (!decoded) return std::move(decoded).error();
            result.pane = Field<Id>(std::move(decoded).value());
        }
    }
    const Json* field_rows = value.find("rows");
    if (field_rows) {
        if (field_rows->is_null()) {
            result.rows = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_rows);
            if (!decoded) return std::move(decoded).error();
            result.rows = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<ScrollSurfaceRequest>::encode(const ScrollSurfaceRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_delta = encode_value(value.delta);
    if (!encoded_delta) return std::move(encoded_delta).error();
    object.emplace("delta", std::move(encoded_delta).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<ScrollSurfaceRequest> Codec<ScrollSurfaceRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ScrollSurfaceRequest result{};
    const Json* field_delta = value.find("delta");
    if (!field_delta) {
        return make_error(ErrorCode::decode, "missing required field 'delta'");
    }
    if (field_delta) {
        auto decoded = decode_value<std::int64_t>(*field_delta);
        if (!decoded) return std::move(decoded).error();
        result.delta = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<SelectScreenRequest>::encode(const SelectScreenRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.delta.is_absent()) {
        auto encoded = encode_value(value.delta);
        if (!encoded) return std::move(encoded).error();
        object.emplace("delta", std::move(encoded).value());
    }
    if (!value.index.is_absent()) {
        auto encoded = encode_value(value.index);
        if (!encoded) return std::move(encoded).error();
        object.emplace("index", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<SelectScreenRequest> Codec<SelectScreenRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SelectScreenRequest result{};
    const Json* field_delta = value.find("delta");
    if (field_delta) {
        if (field_delta->is_null()) {
            result.delta = Field<std::int64_t>::null();
        } else {
            auto decoded = decode_value<std::int64_t>(*field_delta);
            if (!decoded) return std::move(decoded).error();
            result.delta = Field<std::int64_t>(std::move(decoded).value());
        }
    }
    const Json* field_index = value.find("index");
    if (field_index) {
        if (field_index->is_null()) {
            result.index = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_index);
            if (!decoded) return std::move(decoded).error();
            result.index = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<SelectTabRequest>::encode(const SelectTabRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.delta.is_absent()) {
        auto encoded = encode_value(value.delta);
        if (!encoded) return std::move(encoded).error();
        object.emplace("delta", std::move(encoded).value());
    }
    if (!value.index.is_absent()) {
        auto encoded = encode_value(value.index);
        if (!encoded) return std::move(encoded).error();
        object.emplace("index", std::move(encoded).value());
    }
    if (!value.pane.is_absent()) {
        auto encoded = encode_value(value.pane);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pane", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<SelectTabRequest> Codec<SelectTabRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SelectTabRequest result{};
    const Json* field_delta = value.find("delta");
    if (field_delta) {
        if (field_delta->is_null()) {
            result.delta = Field<std::int64_t>::null();
        } else {
            auto decoded = decode_value<std::int64_t>(*field_delta);
            if (!decoded) return std::move(decoded).error();
            result.delta = Field<std::int64_t>(std::move(decoded).value());
        }
    }
    const Json* field_index = value.find("index");
    if (field_index) {
        if (field_index->is_null()) {
            result.index = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_index);
            if (!decoded) return std::move(decoded).error();
            result.index = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    const Json* field_pane = value.find("pane");
    if (field_pane) {
        if (field_pane->is_null()) {
            result.pane = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_pane);
            if (!decoded) return std::move(decoded).error();
            result.pane = Field<Id>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<SelectWorkspaceRequest>::encode(const SelectWorkspaceRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.delta.is_absent()) {
        auto encoded = encode_value(value.delta);
        if (!encoded) return std::move(encoded).error();
        object.emplace("delta", std::move(encoded).value());
    }
    if (!value.index.is_absent()) {
        auto encoded = encode_value(value.index);
        if (!encoded) return std::move(encoded).error();
        object.emplace("index", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<SelectWorkspaceRequest> Codec<SelectWorkspaceRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SelectWorkspaceRequest result{};
    const Json* field_delta = value.find("delta");
    if (field_delta) {
        if (field_delta->is_null()) {
            result.delta = Field<std::int64_t>::null();
        } else {
            auto decoded = decode_value<std::int64_t>(*field_delta);
            if (!decoded) return std::move(decoded).error();
            result.delta = Field<std::int64_t>(std::move(decoded).value());
        }
    }
    const Json* field_index = value.find("index");
    if (field_index) {
        if (field_index->is_null()) {
            result.index = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_index);
            if (!decoded) return std::move(decoded).error();
            result.index = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<SendRequest>::encode(const SendRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.bytes.is_absent()) {
        auto encoded = encode_value(value.bytes);
        if (!encoded) return std::move(encoded).error();
        object.emplace("bytes", std::move(encoded).value());
    }
    if (value.paste) {
        auto encoded = encode_value(*value.paste);
        if (!encoded) return std::move(encoded).error();
        object.emplace("paste", std::move(encoded).value());
    }
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    if (!value.text.is_absent()) {
        auto encoded = encode_value(value.text);
        if (!encoded) return std::move(encoded).error();
        object.emplace("text", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<SendRequest> Codec<SendRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SendRequest result{};
    const Json* field_bytes = value.find("bytes");
    if (field_bytes) {
        if (field_bytes->is_null()) {
            result.bytes = Field<Base64>::null();
        } else {
            auto decoded = decode_value<Base64>(*field_bytes);
            if (!decoded) return std::move(decoded).error();
            result.bytes = Field<Base64>(std::move(decoded).value());
        }
    }
    const Json* field_paste = value.find("paste");
    if (field_paste) {
        auto decoded = decode_value<bool>(*field_paste);
        if (!decoded) return std::move(decoded).error();
        result.paste = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_text = value.find("text");
    if (field_text) {
        if (field_text->is_null()) {
            result.text = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_text);
            if (!decoded) return std::move(decoded).error();
            result.text = Field<std::string>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<SendKeyRequest>::encode(const SendKeyRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_keys = encode_value(value.keys);
    if (!encoded_keys) return std::move(encoded_keys).error();
    object.emplace("keys", std::move(encoded_keys).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<SendKeyRequest> Codec<SendKeyRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SendKeyRequest result{};
    const Json* field_keys = value.find("keys");
    if (!field_keys) {
        return make_error(ErrorCode::decode, "missing required field 'keys'");
    }
    if (field_keys) {
        auto decoded = decode_value<std::vector<std::string>>(*field_keys);
        if (!decoded) return std::move(decoded).error();
        result.keys = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<SetCellPixelsRequest>::encode(const SetCellPixelsRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_height_px = encode_value(value.height_px);
    if (!encoded_height_px) return std::move(encoded_height_px).error();
    object.emplace("height_px", std::move(encoded_height_px).value());
    auto encoded_width_px = encode_value(value.width_px);
    if (!encoded_width_px) return std::move(encoded_width_px).error();
    object.emplace("width_px", std::move(encoded_width_px).value());
    return Json(std::move(object));
}

Result<SetCellPixelsRequest> Codec<SetCellPixelsRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SetCellPixelsRequest result{};
    const Json* field_height_px = value.find("height_px");
    if (!field_height_px) {
        return make_error(ErrorCode::decode, "missing required field 'height_px'");
    }
    if (field_height_px) {
        auto decoded = decode_value<std::uint16_t>(*field_height_px);
        if (!decoded) return std::move(decoded).error();
        result.height_px = std::move(decoded).value();
    }
    const Json* field_width_px = value.find("width_px");
    if (!field_width_px) {
        return make_error(ErrorCode::decode, "missing required field 'width_px'");
    }
    if (field_width_px) {
        auto decoded = decode_value<std::uint16_t>(*field_width_px);
        if (!decoded) return std::move(decoded).error();
        result.width_px = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<SetClientInfoRequest>::encode(const SetClientInfoRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.capabilities.is_absent()) {
        auto encoded = encode_value(value.capabilities);
        if (!encoded) return std::move(encoded).error();
        object.emplace("capabilities", std::move(encoded).value());
    }
    if (!value.kind.is_absent()) {
        auto encoded = encode_value(value.kind);
        if (!encoded) return std::move(encoded).error();
        object.emplace("kind", std::move(encoded).value());
    }
    if (!value.name.is_absent()) {
        auto encoded = encode_value(value.name);
        if (!encoded) return std::move(encoded).error();
        object.emplace("name", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<SetClientInfoRequest> Codec<SetClientInfoRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SetClientInfoRequest result{};
    const Json* field_capabilities = value.find("capabilities");
    if (field_capabilities) {
        if (field_capabilities->is_null()) {
            result.capabilities = Field<std::vector<std::string>>::null();
        } else {
            auto decoded = decode_value<std::vector<std::string>>(*field_capabilities);
            if (!decoded) return std::move(decoded).error();
            result.capabilities = Field<std::vector<std::string>>(std::move(decoded).value());
        }
    }
    const Json* field_kind = value.find("kind");
    if (field_kind) {
        if (field_kind->is_null()) {
            result.kind = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_kind);
            if (!decoded) return std::move(decoded).error();
            result.kind = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_name = value.find("name");
    if (field_name) {
        if (field_name->is_null()) {
            result.name = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_name);
            if (!decoded) return std::move(decoded).error();
            result.name = Field<std::string>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<SetClientSizingRequest>::encode(const SetClientSizingRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.client.is_absent()) {
        auto encoded = encode_value(value.client);
        if (!encoded) return std::move(encoded).error();
        object.emplace("client", std::move(encoded).value());
    }
    auto encoded_enabled = encode_value(value.enabled);
    if (!encoded_enabled) return std::move(encoded_enabled).error();
    object.emplace("enabled", std::move(encoded_enabled).value());
    if (value.exclusive) {
        auto encoded = encode_value(*value.exclusive);
        if (!encoded) return std::move(encoded).error();
        object.emplace("exclusive", std::move(encoded).value());
    }
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<SetClientSizingRequest> Codec<SetClientSizingRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SetClientSizingRequest result{};
    const Json* field_client = value.find("client");
    if (field_client) {
        if (field_client->is_null()) {
            result.client = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_client);
            if (!decoded) return std::move(decoded).error();
            result.client = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    const Json* field_enabled = value.find("enabled");
    if (!field_enabled) {
        return make_error(ErrorCode::decode, "missing required field 'enabled'");
    }
    if (field_enabled) {
        auto decoded = decode_value<bool>(*field_enabled);
        if (!decoded) return std::move(decoded).error();
        result.enabled = std::move(decoded).value();
    }
    const Json* field_exclusive = value.find("exclusive");
    if (field_exclusive) {
        auto decoded = decode_value<bool>(*field_exclusive);
        if (!decoded) return std::move(decoded).error();
        result.exclusive = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<SetDefaultColorsRequest>::encode(const SetDefaultColorsRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.bg.is_absent()) {
        auto encoded = encode_value(value.bg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("bg", std::move(encoded).value());
    }
    if (value.complete) {
        auto encoded = encode_value(*value.complete);
        if (!encoded) return std::move(encoded).error();
        object.emplace("complete", std::move(encoded).value());
    }
    if (!value.cursor.is_absent()) {
        auto encoded = encode_value(value.cursor);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cursor", std::move(encoded).value());
    }
    if (!value.cursor_blink.is_absent()) {
        auto encoded = encode_value(value.cursor_blink);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cursor_blink", std::move(encoded).value());
    }
    if (!value.cursor_style.is_absent()) {
        auto encoded = encode_value(value.cursor_style);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cursor_style", std::move(encoded).value());
    }
    if (!value.fg.is_absent()) {
        auto encoded = encode_value(value.fg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("fg", std::move(encoded).value());
    }
    if (!value.palette.is_absent()) {
        auto encoded = encode_value(value.palette);
        if (!encoded) return std::move(encoded).error();
        object.emplace("palette", std::move(encoded).value());
    }
    if (!value.selection_bg.is_absent()) {
        auto encoded = encode_value(value.selection_bg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("selection_bg", std::move(encoded).value());
    }
    if (!value.selection_fg.is_absent()) {
        auto encoded = encode_value(value.selection_fg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("selection_fg", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<SetDefaultColorsRequest> Codec<SetDefaultColorsRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SetDefaultColorsRequest result{};
    const Json* field_bg = value.find("bg");
    if (field_bg) {
        if (field_bg->is_null()) {
            result.bg = Field<ColorHex>::null();
        } else {
            auto decoded = decode_value<ColorHex>(*field_bg);
            if (!decoded) return std::move(decoded).error();
            result.bg = Field<ColorHex>(std::move(decoded).value());
        }
    }
    const Json* field_complete = value.find("complete");
    if (field_complete) {
        auto decoded = decode_value<bool>(*field_complete);
        if (!decoded) return std::move(decoded).error();
        result.complete = std::move(decoded).value();
    }
    const Json* field_cursor = value.find("cursor");
    if (field_cursor) {
        if (field_cursor->is_null()) {
            result.cursor = Field<ColorHex>::null();
        } else {
            auto decoded = decode_value<ColorHex>(*field_cursor);
            if (!decoded) return std::move(decoded).error();
            result.cursor = Field<ColorHex>(std::move(decoded).value());
        }
    }
    const Json* field_cursor_blink = value.find("cursor_blink");
    if (field_cursor_blink) {
        if (field_cursor_blink->is_null()) {
            result.cursor_blink = Field<bool>::null();
        } else {
            auto decoded = decode_value<bool>(*field_cursor_blink);
            if (!decoded) return std::move(decoded).error();
            result.cursor_blink = Field<bool>(std::move(decoded).value());
        }
    }
    const Json* field_cursor_style = value.find("cursor_style");
    if (field_cursor_style) {
        if (field_cursor_style->is_null()) {
            result.cursor_style = Field<CursorStyle>::null();
        } else {
            auto decoded = decode_value<CursorStyle>(*field_cursor_style);
            if (!decoded) return std::move(decoded).error();
            result.cursor_style = Field<CursorStyle>(std::move(decoded).value());
        }
    }
    const Json* field_fg = value.find("fg");
    if (field_fg) {
        if (field_fg->is_null()) {
            result.fg = Field<ColorHex>::null();
        } else {
            auto decoded = decode_value<ColorHex>(*field_fg);
            if (!decoded) return std::move(decoded).error();
            result.fg = Field<ColorHex>(std::move(decoded).value());
        }
    }
    const Json* field_palette = value.find("palette");
    if (field_palette) {
        if (field_palette->is_null()) {
            result.palette = Field<std::map<std::string, ColorHex, std::less<>>>::null();
        } else {
            auto decoded = decode_value<std::map<std::string, ColorHex, std::less<>>>(*field_palette);
            if (!decoded) return std::move(decoded).error();
            result.palette = Field<std::map<std::string, ColorHex, std::less<>>>(std::move(decoded).value());
        }
    }
    const Json* field_selection_bg = value.find("selection_bg");
    if (field_selection_bg) {
        if (field_selection_bg->is_null()) {
            result.selection_bg = Field<ColorHex>::null();
        } else {
            auto decoded = decode_value<ColorHex>(*field_selection_bg);
            if (!decoded) return std::move(decoded).error();
            result.selection_bg = Field<ColorHex>(std::move(decoded).value());
        }
    }
    const Json* field_selection_fg = value.find("selection_fg");
    if (field_selection_fg) {
        if (field_selection_fg->is_null()) {
            result.selection_fg = Field<ColorHex>::null();
        } else {
            auto decoded = decode_value<ColorHex>(*field_selection_fg);
            if (!decoded) return std::move(decoded).error();
            result.selection_fg = Field<ColorHex>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<SetRatioRequest>::encode(const SetRatioRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_dir = encode_value(value.dir);
    if (!encoded_dir) return std::move(encoded_dir).error();
    object.emplace("dir", std::move(encoded_dir).value());
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    auto encoded_ratio = encode_value(value.ratio);
    if (!encoded_ratio) return std::move(encoded_ratio).error();
    object.emplace("ratio", std::move(encoded_ratio).value());
    return Json(std::move(object));
}

Result<SetRatioRequest> Codec<SetRatioRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SetRatioRequest result{};
    const Json* field_dir = value.find("dir");
    if (!field_dir) {
        return make_error(ErrorCode::decode, "missing required field 'dir'");
    }
    if (field_dir) {
        auto decoded = decode_value<SplitDirection>(*field_dir);
        if (!decoded) return std::move(decoded).error();
        result.dir = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_ratio = value.find("ratio");
    if (!field_ratio) {
        return make_error(ErrorCode::decode, "missing required field 'ratio'");
    }
    if (field_ratio) {
        auto decoded = decode_value<float>(*field_ratio);
        if (!decoded) return std::move(decoded).error();
        result.ratio = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<SetSplitRatioRequest>::encode(const SetSplitRatioRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_ratio = encode_value(value.ratio);
    if (!encoded_ratio) return std::move(encoded_ratio).error();
    object.emplace("ratio", std::move(encoded_ratio).value());
    auto encoded_split = encode_value(value.split);
    if (!encoded_split) return std::move(encoded_split).error();
    object.emplace("split", std::move(encoded_split).value());
    if (!value.transaction.is_absent()) {
        auto encoded = encode_value(value.transaction);
        if (!encoded) return std::move(encoded).error();
        object.emplace("transaction", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<SetSplitRatioRequest> Codec<SetSplitRatioRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SetSplitRatioRequest result{};
    const Json* field_ratio = value.find("ratio");
    if (!field_ratio) {
        return make_error(ErrorCode::decode, "missing required field 'ratio'");
    }
    if (field_ratio) {
        auto decoded = decode_value<float>(*field_ratio);
        if (!decoded) return std::move(decoded).error();
        result.ratio = std::move(decoded).value();
    }
    const Json* field_split = value.find("split");
    if (!field_split) {
        return make_error(ErrorCode::decode, "missing required field 'split'");
    }
    if (field_split) {
        auto decoded = decode_value<Id>(*field_split);
        if (!decoded) return std::move(decoded).error();
        result.split = std::move(decoded).value();
    }
    const Json* field_transaction = value.find("transaction");
    if (field_transaction) {
        if (field_transaction->is_null()) {
            result.transaction = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_transaction);
            if (!decoded) return std::move(decoded).error();
            result.transaction = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<SetViewportPaneWidthRequest>::encode(const SetViewportPaneWidthRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    if (!value.transaction.is_absent()) {
        auto encoded = encode_value(value.transaction);
        if (!encoded) return std::move(encoded).error();
        object.emplace("transaction", std::move(encoded).value());
    }
    auto encoded_width = encode_value(value.width);
    if (!encoded_width) return std::move(encoded_width).error();
    object.emplace("width", std::move(encoded_width).value());
    return Json(std::move(object));
}

Result<SetViewportPaneWidthRequest> Codec<SetViewportPaneWidthRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SetViewportPaneWidthRequest result{};
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_transaction = value.find("transaction");
    if (field_transaction) {
        if (field_transaction->is_null()) {
            result.transaction = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_transaction);
            if (!decoded) return std::move(decoded).error();
            result.transaction = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    const Json* field_width = value.find("width");
    if (!field_width) {
        return make_error(ErrorCode::decode, "missing required field 'width'");
    }
    if (field_width) {
        auto decoded = decode_value<float>(*field_width);
        if (!decoded) return std::move(decoded).error();
        result.width = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<SetWindowTitleRequest>::encode(const SetWindowTitleRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_title = encode_value(value.title);
    if (!encoded_title) return std::move(encoded_title).error();
    object.emplace("title", std::move(encoded_title).value());
    return Json(std::move(object));
}

Result<SetWindowTitleRequest> Codec<SetWindowTitleRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SetWindowTitleRequest result{};
    const Json* field_title = value.find("title");
    if (!field_title) {
        return make_error(ErrorCode::decode, "missing required field 'title'");
    }
    if (field_title) {
        auto decoded = decode_value<std::string>(*field_title);
        if (!decoded) return std::move(decoded).error();
        result.title = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ShutdownDaemonRequest>::encode(const ShutdownDaemonRequest& value) {
    (void)value;
    Json::Object object;
    if (value.force) {
        auto encoded = encode_value(*value.force);
        if (!encoded) return std::move(encoded).error();
        object.emplace("force", std::move(encoded).value());
    }
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    auto encoded_pid = encode_value(value.pid);
    if (!encoded_pid) return std::move(encoded_pid).error();
    object.emplace("pid", std::move(encoded_pid).value());
    return Json(std::move(object));
}

Result<ShutdownDaemonRequest> Codec<ShutdownDaemonRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ShutdownDaemonRequest result{};
    const Json* field_force = value.find("force");
    if (field_force) {
        auto decoded = decode_value<bool>(*field_force);
        if (!decoded) return std::move(decoded).error();
        result.force = std::move(decoded).value();
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_pid = value.find("pid");
    if (!field_pid) {
        return make_error(ErrorCode::decode, "missing required field 'pid'");
    }
    if (field_pid) {
        auto decoded = decode_value<std::uint32_t>(*field_pid);
        if (!decoded) return std::move(decoded).error();
        result.pid = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<SidebarPluginRequest>::encode(const SidebarPluginRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_cols = encode_value(value.cols);
    if (!encoded_cols) return std::move(encoded_cols).error();
    object.emplace("cols", std::move(encoded_cols).value());
    if (value.relaunch) {
        auto encoded = encode_value(*value.relaunch);
        if (!encoded) return std::move(encoded).error();
        object.emplace("relaunch", std::move(encoded).value());
    }
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    return Json(std::move(object));
}

Result<SidebarPluginRequest> Codec<SidebarPluginRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SidebarPluginRequest result{};
    const Json* field_cols = value.find("cols");
    if (!field_cols) {
        return make_error(ErrorCode::decode, "missing required field 'cols'");
    }
    if (field_cols) {
        auto decoded = decode_value<std::uint16_t>(*field_cols);
        if (!decoded) return std::move(decoded).error();
        result.cols = std::move(decoded).value();
    }
    const Json* field_relaunch = value.find("relaunch");
    if (field_relaunch) {
        auto decoded = decode_value<bool>(*field_relaunch);
        if (!decoded) return std::move(decoded).error();
        result.relaunch = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::uint16_t>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<SplitRequest>::encode(const SplitRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.cols.is_absent()) {
        auto encoded = encode_value(value.cols);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cols", std::move(encoded).value());
    }
    auto encoded_dir = encode_value(value.dir);
    if (!encoded_dir) return std::move(encoded_dir).error();
    object.emplace("dir", std::move(encoded_dir).value());
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    if (!value.rows.is_absent()) {
        auto encoded = encode_value(value.rows);
        if (!encoded) return std::move(encoded).error();
        object.emplace("rows", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<SplitRequest> Codec<SplitRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SplitRequest result{};
    const Json* field_cols = value.find("cols");
    if (field_cols) {
        if (field_cols->is_null()) {
            result.cols = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_cols);
            if (!decoded) return std::move(decoded).error();
            result.cols = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    const Json* field_dir = value.find("dir");
    if (!field_dir) {
        return make_error(ErrorCode::decode, "missing required field 'dir'");
    }
    if (field_dir) {
        auto decoded = decode_value<SplitDirection>(*field_dir);
        if (!decoded) return std::move(decoded).error();
        result.dir = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (field_rows) {
        if (field_rows->is_null()) {
            result.rows = Field<std::uint16_t>::null();
        } else {
            auto decoded = decode_value<std::uint16_t>(*field_rows);
            if (!decoded) return std::move(decoded).error();
            result.rows = Field<std::uint16_t>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<SubscribeRequest>::encode(const SubscribeRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.surface.is_absent()) {
        auto encoded = encode_value(value.surface);
        if (!encoded) return std::move(encoded).error();
        object.emplace("surface", std::move(encoded).value());
    }
    if (!value.tree_events.is_absent()) {
        auto encoded = encode_value(value.tree_events);
        if (!encoded) return std::move(encoded).error();
        object.emplace("tree_events", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<SubscribeRequest> Codec<SubscribeRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SubscribeRequest result{};
    const Json* field_surface = value.find("surface");
    if (field_surface) {
        if (field_surface->is_null()) {
            result.surface = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_surface);
            if (!decoded) return std::move(decoded).error();
            result.surface = Field<Id>(std::move(decoded).value());
        }
    }
    const Json* field_tree_events = value.find("tree_events");
    if (field_tree_events) {
        if (field_tree_events->is_null()) {
            result.tree_events = Field<SubscribeRequestTreeEvents>::null();
        } else {
            auto decoded = decode_value<SubscribeRequestTreeEvents>(*field_tree_events);
            if (!decoded) return std::move(decoded).error();
            result.tree_events = Field<SubscribeRequestTreeEvents>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<SwapPaneRequest>::encode(const SwapPaneRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.dir.is_absent()) {
        auto encoded = encode_value(value.dir);
        if (!encoded) return std::move(encoded).error();
        object.emplace("dir", std::move(encoded).value());
    }
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    if (!value.target.is_absent()) {
        auto encoded = encode_value(value.target);
        if (!encoded) return std::move(encoded).error();
        object.emplace("target", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<SwapPaneRequest> Codec<SwapPaneRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SwapPaneRequest result{};
    const Json* field_dir = value.find("dir");
    if (field_dir) {
        if (field_dir->is_null()) {
            result.dir = Field<PaneDirection>::null();
        } else {
            auto decoded = decode_value<PaneDirection>(*field_dir);
            if (!decoded) return std::move(decoded).error();
            result.dir = Field<PaneDirection>(std::move(decoded).value());
        }
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_target = value.find("target");
    if (field_target) {
        if (field_target->is_null()) {
            result.target = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_target);
            if (!decoded) return std::move(decoded).error();
            result.target = Field<Id>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<TerminalEventsRequest>::encode(const TerminalEventsRequest& value) {
    (void)value;
    Json::Object object;
    if (value.after_revision) {
        auto encoded = encode_value(*value.after_revision);
        if (!encoded) return std::move(encoded).error();
        object.emplace("after_revision", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<TerminalEventsRequest> Codec<TerminalEventsRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TerminalEventsRequest result{};
    const Json* field_after_revision = value.find("after_revision");
    if (field_after_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_after_revision);
        if (!decoded) return std::move(decoded).error();
        result.after_revision = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<UndoLayoutRequest>::encode(const UndoLayoutRequest& value) {
    (void)value;
    Json::Object object;
    if (value.confirm_close) {
        auto encoded = encode_value(*value.confirm_close);
        if (!encoded) return std::move(encoded).error();
        object.emplace("confirm_close", std::move(encoded).value());
    }
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    if (!value.revision.is_absent()) {
        auto encoded = encode_value(value.revision);
        if (!encoded) return std::move(encoded).error();
        object.emplace("revision", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<UndoLayoutRequest> Codec<UndoLayoutRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    UndoLayoutRequest result{};
    const Json* field_confirm_close = value.find("confirm_close");
    if (field_confirm_close) {
        auto decoded = decode_value<bool>(*field_confirm_close);
        if (!decoded) return std::move(decoded).error();
        result.confirm_close = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_revision = value.find("revision");
    if (field_revision) {
        if (field_revision->is_null()) {
            result.revision = Field<std::uint64_t>::null();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_revision);
            if (!decoded) return std::move(decoded).error();
            result.revision = Field<std::uint64_t>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<UnregisterBrowserProviderRequest>::encode(const UnregisterBrowserProviderRequest& value) {
    (void)value;
    Json::Object object;
    return Json(std::move(object));
}

Result<UnregisterBrowserProviderRequest> Codec<UnregisterBrowserProviderRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    UnregisterBrowserProviderRequest result{};
    return result;
}

Result<Json> Codec<VtStateRequest>::encode(const VtStateRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<VtStateRequest> Codec<VtStateRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    VtStateRequest result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<WaitForRequest>::encode(const WaitForRequest& value) {
    (void)value;
    Json::Object object;
    auto encoded_pattern = encode_value(value.pattern);
    if (!encoded_pattern) return std::move(encoded_pattern).error();
    object.emplace("pattern", std::move(encoded_pattern).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    auto encoded_timeout_ms = encode_value(value.timeout_ms);
    if (!encoded_timeout_ms) return std::move(encoded_timeout_ms).error();
    object.emplace("timeout_ms", std::move(encoded_timeout_ms).value());
    return Json(std::move(object));
}

Result<WaitForRequest> Codec<WaitForRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    WaitForRequest result{};
    const Json* field_pattern = value.find("pattern");
    if (!field_pattern) {
        return make_error(ErrorCode::decode, "missing required field 'pattern'");
    }
    if (field_pattern) {
        auto decoded = decode_value<std::string>(*field_pattern);
        if (!decoded) return std::move(decoded).error();
        result.pattern = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_timeout_ms = value.find("timeout_ms");
    if (!field_timeout_ms) {
        return make_error(ErrorCode::decode, "missing required field 'timeout_ms'");
    }
    if (field_timeout_ms) {
        auto decoded = decode_value<std::uint64_t>(*field_timeout_ms);
        if (!decoded) return std::move(decoded).error();
        result.timeout_ms = std::move(decoded).value();
    }
    return result;
}

Result<Json> Codec<ZoomPaneRequest>::encode(const ZoomPaneRequest& value) {
    (void)value;
    Json::Object object;
    if (!value.mode.is_absent()) {
        auto encoded = encode_value(value.mode);
        if (!encoded) return std::move(encoded).error();
        object.emplace("mode", std::move(encoded).value());
    }
    if (!value.pane.is_absent()) {
        auto encoded = encode_value(value.pane);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pane", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<ZoomPaneRequest> Codec<ZoomPaneRequest>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ZoomPaneRequest result{};
    const Json* field_mode = value.find("mode");
    if (field_mode) {
        if (field_mode->is_null()) {
            result.mode = Field<ZoomPaneRequestMode>::null();
        } else {
            auto decoded = decode_value<ZoomPaneRequestMode>(*field_mode);
            if (!decoded) return std::move(decoded).error();
            result.mode = Field<ZoomPaneRequestMode>(std::move(decoded).value());
        }
    }
    const Json* field_pane = value.find("pane");
    if (field_pane) {
        if (field_pane->is_null()) {
            result.pane = Field<Id>::null();
        } else {
            auto decoded = decode_value<Id>(*field_pane);
            if (!decoded) return std::move(decoded).error();
            result.pane = Field<Id>(std::move(decoded).value());
        }
    }
    return result;
}

Result<Json> Codec<AgentChangedEvent>::encode(const AgentChangedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("agent-changed")));
    if (value.session) {
        auto encoded = encode_value(*value.session);
        if (!encoded) return std::move(encoded).error();
        object.emplace("session", std::move(encoded).value());
    } else {
        object.emplace("session", Json(nullptr));
    }
    auto encoded_source = encode_value(value.source);
    if (!encoded_source) return std::move(encoded_source).error();
    object.emplace("source", std::move(encoded_source).value());
    auto encoded_state = encode_value(value.state);
    if (!encoded_state) return std::move(encoded_state).error();
    object.emplace("state", std::move(encoded_state).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    auto encoded_updated_at_ms = encode_value(value.updated_at_ms);
    if (!encoded_updated_at_ms) return std::move(encoded_updated_at_ms).error();
    object.emplace("updated_at_ms", std::move(encoded_updated_at_ms).value());
    return Json(std::move(object));
}

Result<AgentChangedEvent> Codec<AgentChangedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    AgentChangedEvent result{};
    const Json* field_session = value.find("session");
    if (!field_session) {
        return make_error(ErrorCode::decode, "missing required field 'session'");
    }
    if (field_session) {
        if (field_session->is_null()) {
            result.session.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_session);
            if (!decoded) return std::move(decoded).error();
            result.session = std::move(decoded).value();
        }
    }
    const Json* field_source = value.find("source");
    if (!field_source) {
        return make_error(ErrorCode::decode, "missing required field 'source'");
    }
    if (field_source) {
        auto decoded = decode_value<AgentSource>(*field_source);
        if (!decoded) return std::move(decoded).error();
        result.source = std::move(decoded).value();
    }
    const Json* field_state = value.find("state");
    if (!field_state) {
        return make_error(ErrorCode::decode, "missing required field 'state'");
    }
    if (field_state) {
        auto decoded = decode_value<AgentState>(*field_state);
        if (!decoded) return std::move(decoded).error();
        result.state = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_updated_at_ms = value.find("updated_at_ms");
    if (!field_updated_at_ms) {
        return make_error(ErrorCode::decode, "missing required field 'updated_at_ms'");
    }
    if (field_updated_at_ms) {
        auto decoded = decode_value<std::uint64_t>(*field_updated_at_ms);
        if (!decoded) return std::move(decoded).error();
        result.updated_at_ms = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("agent-changed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<BellEvent>::encode(const BellEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("bell")));
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<BellEvent> Codec<BellEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BellEvent result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("bell"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<BrowserStateEvent>::encode(const BrowserStateEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("browser-state")));
    auto encoded_cols = encode_value(value.cols);
    if (!encoded_cols) return std::move(encoded_cols).error();
    object.emplace("cols", std::move(encoded_cols).value());
    if (value.error) {
        auto encoded = encode_value(*value.error);
        if (!encoded) return std::move(encoded).error();
        object.emplace("error", std::move(encoded).value());
    } else {
        object.emplace("error", Json(nullptr));
    }
    if (!value.frame.is_absent()) {
        auto encoded = encode_value(value.frame);
        if (!encoded) return std::move(encoded).error();
        object.emplace("frame", std::move(encoded).value());
    }
    auto encoded_frames_stalled = encode_value(value.frames_stalled);
    if (!encoded_frames_stalled) return std::move(encoded_frames_stalled).error();
    object.emplace("frames_stalled", std::move(encoded_frames_stalled).value());
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    auto encoded_status = encode_value(value.status);
    if (!encoded_status) return std::move(encoded_status).error();
    object.emplace("status", std::move(encoded_status).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    auto encoded_title = encode_value(value.title);
    if (!encoded_title) return std::move(encoded_title).error();
    object.emplace("title", std::move(encoded_title).value());
    auto encoded_url = encode_value(value.url);
    if (!encoded_url) return std::move(encoded_url).error();
    object.emplace("url", std::move(encoded_url).value());
    return Json(std::move(object));
}

Result<BrowserStateEvent> Codec<BrowserStateEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    BrowserStateEvent result{};
    const Json* field_cols = value.find("cols");
    if (!field_cols) {
        return make_error(ErrorCode::decode, "missing required field 'cols'");
    }
    if (field_cols) {
        auto decoded = decode_value<std::uint16_t>(*field_cols);
        if (!decoded) return std::move(decoded).error();
        result.cols = std::move(decoded).value();
    }
    const Json* field_error = value.find("error");
    if (!field_error) {
        return make_error(ErrorCode::decode, "missing required field 'error'");
    }
    if (field_error) {
        if (field_error->is_null()) {
            result.error.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_error);
            if (!decoded) return std::move(decoded).error();
            result.error = std::move(decoded).value();
        }
    }
    const Json* field_frame = value.find("frame");
    if (field_frame) {
        if (field_frame->is_null()) {
            result.frame = Field<BrowserFrame>::null();
        } else {
            auto decoded = decode_value<BrowserFrame>(*field_frame);
            if (!decoded) return std::move(decoded).error();
            result.frame = Field<BrowserFrame>(std::move(decoded).value());
        }
    }
    const Json* field_frames_stalled = value.find("frames_stalled");
    if (!field_frames_stalled) {
        return make_error(ErrorCode::decode, "missing required field 'frames_stalled'");
    }
    if (field_frames_stalled) {
        auto decoded = decode_value<bool>(*field_frames_stalled);
        if (!decoded) return std::move(decoded).error();
        result.frames_stalled = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::uint16_t>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    const Json* field_status = value.find("status");
    if (!field_status) {
        return make_error(ErrorCode::decode, "missing required field 'status'");
    }
    if (field_status) {
        auto decoded = decode_value<BrowserStateEventStatus>(*field_status);
        if (!decoded) return std::move(decoded).error();
        result.status = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_title = value.find("title");
    if (!field_title) {
        return make_error(ErrorCode::decode, "missing required field 'title'");
    }
    if (field_title) {
        auto decoded = decode_value<std::string>(*field_title);
        if (!decoded) return std::move(decoded).error();
        result.title = std::move(decoded).value();
    }
    const Json* field_url = value.find("url");
    if (!field_url) {
        return make_error(ErrorCode::decode, "missing required field 'url'");
    }
    if (field_url) {
        auto decoded = decode_value<std::string>(*field_url);
        if (!decoded) return std::move(decoded).error();
        result.url = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("browser-state"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<ClientAttachedEvent>::encode(const ClientAttachedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("client-attached")));
    auto encoded_client = encode_value(value.client);
    if (!encoded_client) return std::move(encoded_client).error();
    object.emplace("client", std::move(encoded_client).value());
    if (value.kind) {
        auto encoded = encode_value(*value.kind);
        if (!encoded) return std::move(encoded).error();
        object.emplace("kind", std::move(encoded).value());
    } else {
        object.emplace("kind", Json(nullptr));
    }
    if (value.name) {
        auto encoded = encode_value(*value.name);
        if (!encoded) return std::move(encoded).error();
        object.emplace("name", std::move(encoded).value());
    } else {
        object.emplace("name", Json(nullptr));
    }
    auto encoded_transport = encode_value(value.transport);
    if (!encoded_transport) return std::move(encoded_transport).error();
    object.emplace("transport", std::move(encoded_transport).value());
    return Json(std::move(object));
}

Result<ClientAttachedEvent> Codec<ClientAttachedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ClientAttachedEvent result{};
    const Json* field_client = value.find("client");
    if (!field_client) {
        return make_error(ErrorCode::decode, "missing required field 'client'");
    }
    if (field_client) {
        auto decoded = decode_value<std::uint64_t>(*field_client);
        if (!decoded) return std::move(decoded).error();
        result.client = std::move(decoded).value();
    }
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        if (field_kind->is_null()) {
            result.kind.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_kind);
            if (!decoded) return std::move(decoded).error();
            result.kind = std::move(decoded).value();
        }
    }
    const Json* field_name = value.find("name");
    if (!field_name) {
        return make_error(ErrorCode::decode, "missing required field 'name'");
    }
    if (field_name) {
        if (field_name->is_null()) {
            result.name.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_name);
            if (!decoded) return std::move(decoded).error();
            result.name = std::move(decoded).value();
        }
    }
    const Json* field_transport = value.find("transport");
    if (!field_transport) {
        return make_error(ErrorCode::decode, "missing required field 'transport'");
    }
    if (field_transport) {
        auto decoded = decode_value<ClientAttachedEventTransport>(*field_transport);
        if (!decoded) return std::move(decoded).error();
        result.transport = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("client-attached"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<ClientChangedEvent>::encode(const ClientChangedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("client-changed")));
    auto encoded_client = encode_value(value.client);
    if (!encoded_client) return std::move(encoded_client).error();
    object.emplace("client", std::move(encoded_client).value());
    if (value.kind) {
        auto encoded = encode_value(*value.kind);
        if (!encoded) return std::move(encoded).error();
        object.emplace("kind", std::move(encoded).value());
    } else {
        object.emplace("kind", Json(nullptr));
    }
    if (value.name) {
        auto encoded = encode_value(*value.name);
        if (!encoded) return std::move(encoded).error();
        object.emplace("name", std::move(encoded).value());
    } else {
        object.emplace("name", Json(nullptr));
    }
    return Json(std::move(object));
}

Result<ClientChangedEvent> Codec<ClientChangedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ClientChangedEvent result{};
    const Json* field_client = value.find("client");
    if (!field_client) {
        return make_error(ErrorCode::decode, "missing required field 'client'");
    }
    if (field_client) {
        auto decoded = decode_value<std::uint64_t>(*field_client);
        if (!decoded) return std::move(decoded).error();
        result.client = std::move(decoded).value();
    }
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        if (field_kind->is_null()) {
            result.kind.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_kind);
            if (!decoded) return std::move(decoded).error();
            result.kind = std::move(decoded).value();
        }
    }
    const Json* field_name = value.find("name");
    if (!field_name) {
        return make_error(ErrorCode::decode, "missing required field 'name'");
    }
    if (field_name) {
        if (field_name->is_null()) {
            result.name.reset();
        } else {
            auto decoded = decode_value<std::string>(*field_name);
            if (!decoded) return std::move(decoded).error();
            result.name = std::move(decoded).value();
        }
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("client-changed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<ClientDetachedEvent>::encode(const ClientDetachedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("client-detached")));
    auto encoded_client = encode_value(value.client);
    if (!encoded_client) return std::move(encoded_client).error();
    object.emplace("client", std::move(encoded_client).value());
    return Json(std::move(object));
}

Result<ClientDetachedEvent> Codec<ClientDetachedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ClientDetachedEvent result{};
    const Json* field_client = value.find("client");
    if (!field_client) {
        return make_error(ErrorCode::decode, "missing required field 'client'");
    }
    if (field_client) {
        auto decoded = decode_value<std::uint64_t>(*field_client);
        if (!decoded) return std::move(decoded).error();
        result.client = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("client-detached"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<ClientListInvalidatedEvent>::encode(const ClientListInvalidatedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("client-list-invalidated")));
    return Json(std::move(object));
}

Result<ClientListInvalidatedEvent> Codec<ClientListInvalidatedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ClientListInvalidatedEvent result{};
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("client-list-invalidated"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<ColorsChangedEvent>::encode(const ColorsChangedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("colors-changed")));
    if (value.bg) {
        auto encoded = encode_value(*value.bg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("bg", std::move(encoded).value());
    } else {
        object.emplace("bg", Json(nullptr));
    }
    if (!value.cursor.is_absent()) {
        auto encoded = encode_value(value.cursor);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cursor", std::move(encoded).value());
    }
    if (!value.cursor_blink.is_absent()) {
        auto encoded = encode_value(value.cursor_blink);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cursor_blink", std::move(encoded).value());
    }
    if (!value.cursor_style.is_absent()) {
        auto encoded = encode_value(value.cursor_style);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cursor_style", std::move(encoded).value());
    }
    if (value.fg) {
        auto encoded = encode_value(*value.fg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("fg", std::move(encoded).value());
    } else {
        object.emplace("fg", Json(nullptr));
    }
    if (value.palette) {
        auto encoded = encode_value(*value.palette);
        if (!encoded) return std::move(encoded).error();
        object.emplace("palette", std::move(encoded).value());
    }
    if (value.selection_bg) {
        auto encoded = encode_value(*value.selection_bg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("selection_bg", std::move(encoded).value());
    } else {
        object.emplace("selection_bg", Json(nullptr));
    }
    if (value.selection_fg) {
        auto encoded = encode_value(*value.selection_fg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("selection_fg", std::move(encoded).value());
    } else {
        object.emplace("selection_fg", Json(nullptr));
    }
    if (value.surface) {
        auto encoded = encode_value(*value.surface);
        if (!encoded) return std::move(encoded).error();
        object.emplace("surface", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<ColorsChangedEvent> Codec<ColorsChangedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ColorsChangedEvent result{};
    const Json* field_bg = value.find("bg");
    if (!field_bg) {
        return make_error(ErrorCode::decode, "missing required field 'bg'");
    }
    if (field_bg) {
        if (field_bg->is_null()) {
            result.bg.reset();
        } else {
            auto decoded = decode_value<ColorHex>(*field_bg);
            if (!decoded) return std::move(decoded).error();
            result.bg = std::move(decoded).value();
        }
    }
    const Json* field_cursor = value.find("cursor");
    if (field_cursor) {
        if (field_cursor->is_null()) {
            result.cursor = Field<ColorHex>::null();
        } else {
            auto decoded = decode_value<ColorHex>(*field_cursor);
            if (!decoded) return std::move(decoded).error();
            result.cursor = Field<ColorHex>(std::move(decoded).value());
        }
    }
    const Json* field_cursor_blink = value.find("cursor_blink");
    if (field_cursor_blink) {
        if (field_cursor_blink->is_null()) {
            result.cursor_blink = Field<bool>::null();
        } else {
            auto decoded = decode_value<bool>(*field_cursor_blink);
            if (!decoded) return std::move(decoded).error();
            result.cursor_blink = Field<bool>(std::move(decoded).value());
        }
    }
    const Json* field_cursor_style = value.find("cursor_style");
    if (field_cursor_style) {
        if (field_cursor_style->is_null()) {
            result.cursor_style = Field<CursorStyle>::null();
        } else {
            auto decoded = decode_value<CursorStyle>(*field_cursor_style);
            if (!decoded) return std::move(decoded).error();
            result.cursor_style = Field<CursorStyle>(std::move(decoded).value());
        }
    }
    const Json* field_fg = value.find("fg");
    if (!field_fg) {
        return make_error(ErrorCode::decode, "missing required field 'fg'");
    }
    if (field_fg) {
        if (field_fg->is_null()) {
            result.fg.reset();
        } else {
            auto decoded = decode_value<ColorHex>(*field_fg);
            if (!decoded) return std::move(decoded).error();
            result.fg = std::move(decoded).value();
        }
    }
    const Json* field_palette = value.find("palette");
    if (field_palette) {
        auto decoded = decode_value<std::map<std::string, ColorHex, std::less<>>>(*field_palette);
        if (!decoded) return std::move(decoded).error();
        result.palette = std::move(decoded).value();
    }
    const Json* field_selection_bg = value.find("selection_bg");
    if (!field_selection_bg) {
        return make_error(ErrorCode::decode, "missing required field 'selection_bg'");
    }
    if (field_selection_bg) {
        if (field_selection_bg->is_null()) {
            result.selection_bg.reset();
        } else {
            auto decoded = decode_value<ColorHex>(*field_selection_bg);
            if (!decoded) return std::move(decoded).error();
            result.selection_bg = std::move(decoded).value();
        }
    }
    const Json* field_selection_fg = value.find("selection_fg");
    if (!field_selection_fg) {
        return make_error(ErrorCode::decode, "missing required field 'selection_fg'");
    }
    if (field_selection_fg) {
        if (field_selection_fg->is_null()) {
            result.selection_fg.reset();
        } else {
            auto decoded = decode_value<ColorHex>(*field_selection_fg);
            if (!decoded) return std::move(decoded).error();
            result.selection_fg = std::move(decoded).value();
        }
    }
    const Json* field_surface = value.find("surface");
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("colors-changed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<ConfigReloadRequestedEvent>::encode(const ConfigReloadRequestedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("config-reload-requested")));
    return Json(std::move(object));
}

Result<ConfigReloadRequestedEvent> Codec<ConfigReloadRequestedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ConfigReloadRequestedEvent result{};
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("config-reload-requested"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<DetachedEvent>::encode(const DetachedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("detached")));
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<DetachedEvent> Codec<DetachedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    DetachedEvent result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("detached"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<EmptyEvent>::encode(const EmptyEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("empty")));
    return Json(std::move(object));
}

Result<EmptyEvent> Codec<EmptyEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    EmptyEvent result{};
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("empty"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<FrameEvent>::encode(const FrameEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("frame")));
    auto encoded_data = encode_value(value.data);
    if (!encoded_data) return std::move(encoded_data).error();
    object.emplace("data", std::move(encoded_data).value());
    auto encoded_height = encode_value(value.height);
    if (!encoded_height) return std::move(encoded_height).error();
    object.emplace("height", std::move(encoded_height).value());
    auto encoded_seq = encode_value(value.seq);
    if (!encoded_seq) return std::move(encoded_seq).error();
    object.emplace("seq", std::move(encoded_seq).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    auto encoded_width = encode_value(value.width);
    if (!encoded_width) return std::move(encoded_width).error();
    object.emplace("width", std::move(encoded_width).value());
    return Json(std::move(object));
}

Result<FrameEvent> Codec<FrameEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    FrameEvent result{};
    const Json* field_data = value.find("data");
    if (!field_data) {
        return make_error(ErrorCode::decode, "missing required field 'data'");
    }
    if (field_data) {
        auto decoded = decode_value<Base64>(*field_data);
        if (!decoded) return std::move(decoded).error();
        result.data = std::move(decoded).value();
    }
    const Json* field_height = value.find("height");
    if (!field_height) {
        return make_error(ErrorCode::decode, "missing required field 'height'");
    }
    if (field_height) {
        auto decoded = decode_value<std::uint32_t>(*field_height);
        if (!decoded) return std::move(decoded).error();
        result.height = std::move(decoded).value();
    }
    const Json* field_seq = value.find("seq");
    if (!field_seq) {
        return make_error(ErrorCode::decode, "missing required field 'seq'");
    }
    if (field_seq) {
        auto decoded = decode_value<std::uint64_t>(*field_seq);
        if (!decoded) return std::move(decoded).error();
        result.seq = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_width = value.find("width");
    if (!field_width) {
        return make_error(ErrorCode::decode, "missing required field 'width'");
    }
    if (field_width) {
        auto decoded = decode_value<std::uint32_t>(*field_width);
        if (!decoded) return std::move(decoded).error();
        result.width = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("frame"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<FrontendProjectionChangedEvent>::encode(const FrontendProjectionChangedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("frontend-projection-changed")));
    auto encoded_frontend = encode_value(value.frontend);
    if (!encoded_frontend) return std::move(encoded_frontend).error();
    object.emplace("frontend", std::move(encoded_frontend).value());
    auto encoded_mutation_id = encode_value(value.mutation_id);
    if (!encoded_mutation_id) return std::move(encoded_mutation_id).error();
    object.emplace("mutation_id", std::move(encoded_mutation_id).value());
    auto encoded_origin = encode_value(value.origin);
    if (!encoded_origin) return std::move(encoded_origin).error();
    object.emplace("origin", std::move(encoded_origin).value());
    auto encoded_projection_revision = encode_value(value.projection_revision);
    if (!encoded_projection_revision) return std::move(encoded_projection_revision).error();
    object.emplace("projection_revision", std::move(encoded_projection_revision).value());
    auto encoded_scope = encode_value(value.scope);
    if (!encoded_scope) return std::move(encoded_scope).error();
    object.emplace("scope", std::move(encoded_scope).value());
    auto encoded_subject_key = encode_value(value.subject_key);
    if (!encoded_subject_key) return std::move(encoded_subject_key).error();
    object.emplace("subject_key", std::move(encoded_subject_key).value());
    return Json(std::move(object));
}

Result<FrontendProjectionChangedEvent> Codec<FrontendProjectionChangedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    FrontendProjectionChangedEvent result{};
    const Json* field_frontend = value.find("frontend");
    if (!field_frontend) {
        return make_error(ErrorCode::decode, "missing required field 'frontend'");
    }
    if (field_frontend) {
        auto decoded = decode_value<std::string>(*field_frontend);
        if (!decoded) return std::move(decoded).error();
        result.frontend = std::move(decoded).value();
    }
    const Json* field_mutation_id = value.find("mutation_id");
    if (!field_mutation_id) {
        return make_error(ErrorCode::decode, "missing required field 'mutation_id'");
    }
    if (field_mutation_id) {
        auto decoded = decode_value<std::string>(*field_mutation_id);
        if (!decoded) return std::move(decoded).error();
        result.mutation_id = std::move(decoded).value();
    }
    const Json* field_origin = value.find("origin");
    if (!field_origin) {
        return make_error(ErrorCode::decode, "missing required field 'origin'");
    }
    if (field_origin) {
        auto decoded = decode_value<std::string>(*field_origin);
        if (!decoded) return std::move(decoded).error();
        result.origin = std::move(decoded).value();
    }
    const Json* field_projection_revision = value.find("projection_revision");
    if (!field_projection_revision) {
        return make_error(ErrorCode::decode, "missing required field 'projection_revision'");
    }
    if (field_projection_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_projection_revision);
        if (!decoded) return std::move(decoded).error();
        result.projection_revision = std::move(decoded).value();
    }
    const Json* field_scope = value.find("scope");
    if (!field_scope) {
        return make_error(ErrorCode::decode, "missing required field 'scope'");
    }
    if (field_scope) {
        auto decoded = decode_value<std::string>(*field_scope);
        if (!decoded) return std::move(decoded).error();
        result.scope = std::move(decoded).value();
    }
    const Json* field_subject_key = value.find("subject_key");
    if (!field_subject_key) {
        return make_error(ErrorCode::decode, "missing required field 'subject_key'");
    }
    if (field_subject_key) {
        auto decoded = decode_value<std::string>(*field_subject_key);
        if (!decoded) return std::move(decoded).error();
        result.subject_key = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("frontend-projection-changed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<GraphicsStatusEvent>::encode(const GraphicsStatusEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("graphics-status")));
    if (value.attempts) {
        auto encoded = encode_value(*value.attempts);
        if (!encoded) return std::move(encoded).error();
        object.emplace("attempts", std::move(encoded).value());
    }
    if (value.cell_height) {
        auto encoded = encode_value(*value.cell_height);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cell_height", std::move(encoded).value());
    }
    if (value.cell_width) {
        auto encoded = encode_value(*value.cell_width);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cell_width", std::move(encoded).value());
    }
    if (value.error) {
        auto encoded = encode_value(*value.error);
        if (!encoded) return std::move(encoded).error();
        object.emplace("error", std::move(encoded).value());
    }
    auto encoded_kind = encode_value(value.kind);
    if (!encoded_kind) return std::move(encoded_kind).error();
    object.emplace("kind", std::move(encoded_kind).value());
    if (value.remaining) {
        auto encoded = encode_value(*value.remaining);
        if (!encoded) return std::move(encoded).error();
        object.emplace("remaining", std::move(encoded).value());
    }
    if (value.retry_exhausted) {
        auto encoded = encode_value(*value.retry_exhausted);
        if (!encoded) return std::move(encoded).error();
        object.emplace("retry_exhausted", std::move(encoded).value());
    }
    if (value.summary) {
        auto encoded = encode_value(*value.summary);
        if (!encoded) return std::move(encoded).error();
        object.emplace("summary", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<GraphicsStatusEvent> Codec<GraphicsStatusEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    GraphicsStatusEvent result{};
    const Json* field_attempts = value.find("attempts");
    if (field_attempts) {
        auto decoded = decode_value<std::uint16_t>(*field_attempts);
        if (!decoded) return std::move(decoded).error();
        result.attempts = std::move(decoded).value();
    }
    const Json* field_cell_height = value.find("cell_height");
    if (field_cell_height) {
        auto decoded = decode_value<std::uint16_t>(*field_cell_height);
        if (!decoded) return std::move(decoded).error();
        result.cell_height = std::move(decoded).value();
    }
    const Json* field_cell_width = value.find("cell_width");
    if (field_cell_width) {
        auto decoded = decode_value<std::uint16_t>(*field_cell_width);
        if (!decoded) return std::move(decoded).error();
        result.cell_width = std::move(decoded).value();
    }
    const Json* field_error = value.find("error");
    if (field_error) {
        auto decoded = decode_value<std::string>(*field_error);
        if (!decoded) return std::move(decoded).error();
        result.error = std::move(decoded).value();
    }
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        auto decoded = decode_value<GraphicsStatusEventKind>(*field_kind);
        if (!decoded) return std::move(decoded).error();
        result.kind = std::move(decoded).value();
    }
    const Json* field_remaining = value.find("remaining");
    if (field_remaining) {
        auto decoded = decode_value<std::uint64_t>(*field_remaining);
        if (!decoded) return std::move(decoded).error();
        result.remaining = std::move(decoded).value();
    }
    const Json* field_retry_exhausted = value.find("retry_exhausted");
    if (field_retry_exhausted) {
        auto decoded = decode_value<bool>(*field_retry_exhausted);
        if (!decoded) return std::move(decoded).error();
        result.retry_exhausted = std::move(decoded).value();
    }
    const Json* field_summary = value.find("summary");
    if (field_summary) {
        auto decoded = decode_value<std::string>(*field_summary);
        if (!decoded) return std::move(decoded).error();
        result.summary = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("graphics-status"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<LayoutChangedEvent>::encode(const LayoutChangedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("layout-changed")));
    auto encoded_screen = encode_value(value.screen);
    if (!encoded_screen) return std::move(encoded_screen).error();
    object.emplace("screen", std::move(encoded_screen).value());
    return Json(std::move(object));
}

Result<LayoutChangedEvent> Codec<LayoutChangedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    LayoutChangedEvent result{};
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        auto decoded = decode_value<Id>(*field_screen);
        if (!decoded) return std::move(decoded).error();
        result.screen = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("layout-changed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<NotificationEvent>::encode(const NotificationEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("notification")));
    auto encoded_body = encode_value(value.body);
    if (!encoded_body) return std::move(encoded_body).error();
    object.emplace("body", std::move(encoded_body).value());
    auto encoded_level = encode_value(value.level);
    if (!encoded_level) return std::move(encoded_level).error();
    object.emplace("level", std::move(encoded_level).value());
    auto encoded_notification = encode_value(value.notification);
    if (!encoded_notification) return std::move(encoded_notification).error();
    object.emplace("notification", std::move(encoded_notification).value());
    if (value.surface) {
        auto encoded = encode_value(*value.surface);
        if (!encoded) return std::move(encoded).error();
        object.emplace("surface", std::move(encoded).value());
    } else {
        object.emplace("surface", Json(nullptr));
    }
    auto encoded_title = encode_value(value.title);
    if (!encoded_title) return std::move(encoded_title).error();
    object.emplace("title", std::move(encoded_title).value());
    return Json(std::move(object));
}

Result<NotificationEvent> Codec<NotificationEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    NotificationEvent result{};
    const Json* field_body = value.find("body");
    if (!field_body) {
        return make_error(ErrorCode::decode, "missing required field 'body'");
    }
    if (field_body) {
        auto decoded = decode_value<std::string>(*field_body);
        if (!decoded) return std::move(decoded).error();
        result.body = std::move(decoded).value();
    }
    const Json* field_level = value.find("level");
    if (!field_level) {
        return make_error(ErrorCode::decode, "missing required field 'level'");
    }
    if (field_level) {
        auto decoded = decode_value<NotificationLevel>(*field_level);
        if (!decoded) return std::move(decoded).error();
        result.level = std::move(decoded).value();
    }
    const Json* field_notification = value.find("notification");
    if (!field_notification) {
        return make_error(ErrorCode::decode, "missing required field 'notification'");
    }
    if (field_notification) {
        auto decoded = decode_value<Id>(*field_notification);
        if (!decoded) return std::move(decoded).error();
        result.notification = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        if (field_surface->is_null()) {
            result.surface.reset();
        } else {
            auto decoded = decode_value<Id>(*field_surface);
            if (!decoded) return std::move(decoded).error();
            result.surface = std::move(decoded).value();
        }
    }
    const Json* field_title = value.find("title");
    if (!field_title) {
        return make_error(ErrorCode::decode, "missing required field 'title'");
    }
    if (field_title) {
        auto decoded = decode_value<std::string>(*field_title);
        if (!decoded) return std::move(decoded).error();
        result.title = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("notification"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<OutputEvent>::encode(const OutputEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("output")));
    if (value.colors) {
        auto encoded = encode_value(*value.colors);
        if (!encoded) return std::move(encoded).error();
        object.emplace("colors", std::move(encoded).value());
    }
    auto encoded_data = encode_value(value.data);
    if (!encoded_data) return std::move(encoded_data).error();
    object.emplace("data", std::move(encoded_data).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<OutputEvent> Codec<OutputEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    OutputEvent result{};
    const Json* field_colors = value.find("colors");
    if (field_colors) {
        auto decoded = decode_value<TerminalColors>(*field_colors);
        if (!decoded) return std::move(decoded).error();
        result.colors = std::move(decoded).value();
    }
    const Json* field_data = value.find("data");
    if (!field_data) {
        return make_error(ErrorCode::decode, "missing required field 'data'");
    }
    if (field_data) {
        auto decoded = decode_value<Base64>(*field_data);
        if (!decoded) return std::move(decoded).error();
        result.data = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("output"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<OverflowEvent>::encode(const OverflowEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("overflow")));
    auto encoded_error = encode_value(value.error);
    if (!encoded_error) return std::move(encoded_error).error();
    object.emplace("error", std::move(encoded_error).value());
    if (value.scope) {
        auto encoded = encode_value(*value.scope);
        if (!encoded) return std::move(encoded).error();
        if (encoded.value() != Json(std::string("surface"))) {
            return make_error(ErrorCode::invalid_argument, "field 'scope' has the wrong literal value");
        }
        object.emplace("scope", std::move(encoded).value());
    }
    if (value.surface) {
        auto encoded = encode_value(*value.surface);
        if (!encoded) return std::move(encoded).error();
        object.emplace("surface", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<OverflowEvent> Codec<OverflowEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    OverflowEvent result{};
    const Json* field_error = value.find("error");
    if (!field_error) {
        return make_error(ErrorCode::decode, "missing required field 'error'");
    }
    if (field_error) {
        auto decoded = decode_value<std::string>(*field_error);
        if (!decoded) return std::move(decoded).error();
        result.error = std::move(decoded).value();
    }
    const Json* field_scope = value.find("scope");
    if (field_scope) {
        if (*field_scope != Json(std::string("surface"))) {
            return make_error(ErrorCode::decode, "field 'scope' has the wrong literal value");
        }
        result.scope = std::string("surface");
    }
    const Json* field_surface = value.find("surface");
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("overflow"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<PairingRequestedEvent>::encode(const PairingRequestedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("pairing-requested")));
    auto encoded_code = encode_value(value.code);
    if (!encoded_code) return std::move(encoded_code).error();
    object.emplace("code", std::move(encoded_code).value());
    auto encoded_expires_in = encode_value(value.expires_in);
    if (!encoded_expires_in) return std::move(encoded_expires_in).error();
    object.emplace("expires_in", std::move(encoded_expires_in).value());
    auto encoded_peer = encode_value(value.peer);
    if (!encoded_peer) return std::move(encoded_peer).error();
    object.emplace("peer", std::move(encoded_peer).value());
    auto encoded_request = encode_value(value.request);
    if (!encoded_request) return std::move(encoded_request).error();
    object.emplace("request", std::move(encoded_request).value());
    return Json(std::move(object));
}

Result<PairingRequestedEvent> Codec<PairingRequestedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    PairingRequestedEvent result{};
    const Json* field_code = value.find("code");
    if (!field_code) {
        return make_error(ErrorCode::decode, "missing required field 'code'");
    }
    if (field_code) {
        auto decoded = decode_value<std::string>(*field_code);
        if (!decoded) return std::move(decoded).error();
        result.code = std::move(decoded).value();
    }
    const Json* field_expires_in = value.find("expires_in");
    if (!field_expires_in) {
        return make_error(ErrorCode::decode, "missing required field 'expires_in'");
    }
    if (field_expires_in) {
        auto decoded = decode_value<std::uint64_t>(*field_expires_in);
        if (!decoded) return std::move(decoded).error();
        result.expires_in = std::move(decoded).value();
    }
    const Json* field_peer = value.find("peer");
    if (!field_peer) {
        return make_error(ErrorCode::decode, "missing required field 'peer'");
    }
    if (field_peer) {
        auto decoded = decode_value<std::string>(*field_peer);
        if (!decoded) return std::move(decoded).error();
        result.peer = std::move(decoded).value();
    }
    const Json* field_request = value.find("request");
    if (!field_request) {
        return make_error(ErrorCode::decode, "missing required field 'request'");
    }
    if (field_request) {
        auto decoded = decode_value<std::uint64_t>(*field_request);
        if (!decoded) return std::move(decoded).error();
        result.request = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("pairing-requested"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<PairingResolvedEvent>::encode(const PairingResolvedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("pairing-resolved")));
    auto encoded_request = encode_value(value.request);
    if (!encoded_request) return std::move(encoded_request).error();
    object.emplace("request", std::move(encoded_request).value());
    return Json(std::move(object));
}

Result<PairingResolvedEvent> Codec<PairingResolvedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    PairingResolvedEvent result{};
    const Json* field_request = value.find("request");
    if (!field_request) {
        return make_error(ErrorCode::decode, "missing required field 'request'");
    }
    if (field_request) {
        auto decoded = decode_value<std::uint64_t>(*field_request);
        if (!decoded) return std::move(decoded).error();
        result.request = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("pairing-resolved"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<PaneAddedEvent>::encode(const PaneAddedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("pane-added")));
    auto encoded_entity = encode_value(value.entity);
    if (!encoded_entity) return std::move(encoded_entity).error();
    object.emplace("entity", std::move(encoded_entity).value());
    auto encoded_index = encode_value(value.index);
    if (!encoded_index) return std::move(encoded_index).error();
    object.emplace("index", std::move(encoded_index).value());
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    auto encoded_screen = encode_value(value.screen);
    if (!encoded_screen) return std::move(encoded_screen).error();
    object.emplace("screen", std::move(encoded_screen).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    return Json(std::move(object));
}

Result<PaneAddedEvent> Codec<PaneAddedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    PaneAddedEvent result{};
    const Json* field_entity = value.find("entity");
    if (!field_entity) {
        return make_error(ErrorCode::decode, "missing required field 'entity'");
    }
    if (field_entity) {
        auto decoded = decode_value<Pane>(*field_entity);
        if (!decoded) return std::move(decoded).error();
        result.entity = std::move(decoded).value();
    }
    const Json* field_index = value.find("index");
    if (!field_index) {
        return make_error(ErrorCode::decode, "missing required field 'index'");
    }
    if (field_index) {
        auto decoded = decode_value<std::uint64_t>(*field_index);
        if (!decoded) return std::move(decoded).error();
        result.index = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        auto decoded = decode_value<Id>(*field_screen);
        if (!decoded) return std::move(decoded).error();
        result.screen = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("pane-added"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<PaneClosedEvent>::encode(const PaneClosedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("pane-closed")));
    auto encoded_entity = encode_value(value.entity);
    if (!encoded_entity) return std::move(encoded_entity).error();
    object.emplace("entity", std::move(encoded_entity).value());
    auto encoded_index = encode_value(value.index);
    if (!encoded_index) return std::move(encoded_index).error();
    object.emplace("index", std::move(encoded_index).value());
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    auto encoded_screen = encode_value(value.screen);
    if (!encoded_screen) return std::move(encoded_screen).error();
    object.emplace("screen", std::move(encoded_screen).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    return Json(std::move(object));
}

Result<PaneClosedEvent> Codec<PaneClosedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    PaneClosedEvent result{};
    const Json* field_entity = value.find("entity");
    if (!field_entity) {
        return make_error(ErrorCode::decode, "missing required field 'entity'");
    }
    if (field_entity) {
        auto decoded = decode_value<Pane>(*field_entity);
        if (!decoded) return std::move(decoded).error();
        result.entity = std::move(decoded).value();
    }
    const Json* field_index = value.find("index");
    if (!field_index) {
        return make_error(ErrorCode::decode, "missing required field 'index'");
    }
    if (field_index) {
        auto decoded = decode_value<std::uint64_t>(*field_index);
        if (!decoded) return std::move(decoded).error();
        result.index = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        auto decoded = decode_value<Id>(*field_screen);
        if (!decoded) return std::move(decoded).error();
        result.screen = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("pane-closed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<RenderDeltaEvent>::encode(const RenderDeltaEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("render-delta")));
    auto encoded_cursor = encode_value(value.cursor);
    if (!encoded_cursor) return std::move(encoded_cursor).error();
    object.emplace("cursor", std::move(encoded_cursor).value());
    if (value.default_bg) {
        auto encoded = encode_value(*value.default_bg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("default_bg", std::move(encoded).value());
    }
    if (value.default_fg) {
        auto encoded = encode_value(*value.default_fg);
        if (!encoded) return std::move(encoded).error();
        object.emplace("default_fg", std::move(encoded).value());
    }
    auto encoded_full = encode_value(value.full);
    if (!encoded_full) return std::move(encoded_full).error();
    object.emplace("full", std::move(encoded_full).value());
    if (value.graphics) {
        auto encoded = encode_value(*value.graphics);
        if (!encoded) return std::move(encoded).error();
        object.emplace("graphics", std::move(encoded).value());
    }
    if (value.history_epoch) {
        auto encoded = encode_value(*value.history_epoch);
        if (!encoded) return std::move(encoded).error();
        object.emplace("history_epoch", std::move(encoded).value());
    }
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    if (value.scrollback_rows) {
        auto encoded = encode_value(*value.scrollback_rows);
        if (!encoded) return std::move(encoded).error();
        object.emplace("scrollback_rows", std::move(encoded).value());
    }
    if (value.size) {
        auto encoded = encode_value(*value.size);
        if (!encoded) return std::move(encoded).error();
        object.emplace("size", std::move(encoded).value());
    }
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<RenderDeltaEvent> Codec<RenderDeltaEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RenderDeltaEvent result{};
    const Json* field_cursor = value.find("cursor");
    if (!field_cursor) {
        return make_error(ErrorCode::decode, "missing required field 'cursor'");
    }
    if (field_cursor) {
        auto decoded = decode_value<RenderCursor>(*field_cursor);
        if (!decoded) return std::move(decoded).error();
        result.cursor = std::move(decoded).value();
    }
    const Json* field_default_bg = value.find("default_bg");
    if (field_default_bg) {
        auto decoded = decode_value<ColorHex>(*field_default_bg);
        if (!decoded) return std::move(decoded).error();
        result.default_bg = std::move(decoded).value();
    }
    const Json* field_default_fg = value.find("default_fg");
    if (field_default_fg) {
        auto decoded = decode_value<ColorHex>(*field_default_fg);
        if (!decoded) return std::move(decoded).error();
        result.default_fg = std::move(decoded).value();
    }
    const Json* field_full = value.find("full");
    if (!field_full) {
        return make_error(ErrorCode::decode, "missing required field 'full'");
    }
    if (field_full) {
        auto decoded = decode_value<bool>(*field_full);
        if (!decoded) return std::move(decoded).error();
        result.full = std::move(decoded).value();
    }
    const Json* field_graphics = value.find("graphics");
    if (field_graphics) {
        auto decoded = decode_value<RenderGraphicsDelta>(*field_graphics);
        if (!decoded) return std::move(decoded).error();
        result.graphics = std::move(decoded).value();
    }
    const Json* field_history_epoch = value.find("history_epoch");
    if (field_history_epoch) {
        auto decoded = decode_value<std::uint64_t>(*field_history_epoch);
        if (!decoded) return std::move(decoded).error();
        result.history_epoch = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::vector<RenderRow>>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    const Json* field_scrollback_rows = value.find("scrollback_rows");
    if (field_scrollback_rows) {
        auto decoded = decode_value<std::uint32_t>(*field_scrollback_rows);
        if (!decoded) return std::move(decoded).error();
        result.scrollback_rows = std::move(decoded).value();
    }
    const Json* field_size = value.find("size");
    if (field_size) {
        auto decoded = decode_value<Size>(*field_size);
        if (!decoded) return std::move(decoded).error();
        result.size = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("render-delta"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<RenderStateEvent>::encode(const RenderStateEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("render-state")));
    auto encoded_cursor = encode_value(value.cursor);
    if (!encoded_cursor) return std::move(encoded_cursor).error();
    object.emplace("cursor", std::move(encoded_cursor).value());
    auto encoded_default_bg = encode_value(value.default_bg);
    if (!encoded_default_bg) return std::move(encoded_default_bg).error();
    object.emplace("default_bg", std::move(encoded_default_bg).value());
    auto encoded_default_fg = encode_value(value.default_fg);
    if (!encoded_default_fg) return std::move(encoded_default_fg).error();
    object.emplace("default_fg", std::move(encoded_default_fg).value());
    if (value.graphics) {
        auto encoded = encode_value(*value.graphics);
        if (!encoded) return std::move(encoded).error();
        object.emplace("graphics", std::move(encoded).value());
    }
    auto encoded_history_epoch = encode_value(value.history_epoch);
    if (!encoded_history_epoch) return std::move(encoded_history_epoch).error();
    object.emplace("history_epoch", std::move(encoded_history_epoch).value());
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    auto encoded_scrollback_rows = encode_value(value.scrollback_rows);
    if (!encoded_scrollback_rows) return std::move(encoded_scrollback_rows).error();
    object.emplace("scrollback_rows", std::move(encoded_scrollback_rows).value());
    auto encoded_size = encode_value(value.size);
    if (!encoded_size) return std::move(encoded_size).error();
    object.emplace("size", std::move(encoded_size).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<RenderStateEvent> Codec<RenderStateEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    RenderStateEvent result{};
    const Json* field_cursor = value.find("cursor");
    if (!field_cursor) {
        return make_error(ErrorCode::decode, "missing required field 'cursor'");
    }
    if (field_cursor) {
        auto decoded = decode_value<RenderCursor>(*field_cursor);
        if (!decoded) return std::move(decoded).error();
        result.cursor = std::move(decoded).value();
    }
    const Json* field_default_bg = value.find("default_bg");
    if (!field_default_bg) {
        return make_error(ErrorCode::decode, "missing required field 'default_bg'");
    }
    if (field_default_bg) {
        auto decoded = decode_value<ColorHex>(*field_default_bg);
        if (!decoded) return std::move(decoded).error();
        result.default_bg = std::move(decoded).value();
    }
    const Json* field_default_fg = value.find("default_fg");
    if (!field_default_fg) {
        return make_error(ErrorCode::decode, "missing required field 'default_fg'");
    }
    if (field_default_fg) {
        auto decoded = decode_value<ColorHex>(*field_default_fg);
        if (!decoded) return std::move(decoded).error();
        result.default_fg = std::move(decoded).value();
    }
    const Json* field_graphics = value.find("graphics");
    if (field_graphics) {
        auto decoded = decode_value<RenderGraphics>(*field_graphics);
        if (!decoded) return std::move(decoded).error();
        result.graphics = std::move(decoded).value();
    }
    const Json* field_history_epoch = value.find("history_epoch");
    if (!field_history_epoch) {
        return make_error(ErrorCode::decode, "missing required field 'history_epoch'");
    }
    if (field_history_epoch) {
        auto decoded = decode_value<std::uint64_t>(*field_history_epoch);
        if (!decoded) return std::move(decoded).error();
        result.history_epoch = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::vector<RenderRow>>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    const Json* field_scrollback_rows = value.find("scrollback_rows");
    if (!field_scrollback_rows) {
        return make_error(ErrorCode::decode, "missing required field 'scrollback_rows'");
    }
    if (field_scrollback_rows) {
        auto decoded = decode_value<std::uint32_t>(*field_scrollback_rows);
        if (!decoded) return std::move(decoded).error();
        result.scrollback_rows = std::move(decoded).value();
    }
    const Json* field_size = value.find("size");
    if (!field_size) {
        return make_error(ErrorCode::decode, "missing required field 'size'");
    }
    if (field_size) {
        auto decoded = decode_value<Size>(*field_size);
        if (!decoded) return std::move(decoded).error();
        result.size = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("render-state"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<ResizedEvent>::encode(const ResizedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("resized")));
    if (value.colors) {
        auto encoded = encode_value(*value.colors);
        if (!encoded) return std::move(encoded).error();
        object.emplace("colors", std::move(encoded).value());
    }
    auto encoded_cols = encode_value(value.cols);
    if (!encoded_cols) return std::move(encoded_cols).error();
    object.emplace("cols", std::move(encoded_cols).value());
    if (value.data) {
        auto encoded = encode_value(*value.data);
        if (!encoded) return std::move(encoded).error();
        object.emplace("data", std::move(encoded).value());
    }
    if (value.kitty_graphics_state) {
        auto encoded = encode_value(*value.kitty_graphics_state);
        if (!encoded) return std::move(encoded).error();
        object.emplace("kitty_graphics_state", std::move(encoded).value());
    }
    if (value.kitty_image_aliases) {
        auto encoded = encode_value(*value.kitty_image_aliases);
        if (!encoded) return std::move(encoded).error();
        object.emplace("kitty_image_aliases", std::move(encoded).value());
    }
    if (value.replay) {
        auto encoded = encode_value(*value.replay);
        if (!encoded) return std::move(encoded).error();
        object.emplace("replay", std::move(encoded).value());
    }
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<ResizedEvent> Codec<ResizedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ResizedEvent result{};
    const Json* field_colors = value.find("colors");
    if (field_colors) {
        auto decoded = decode_value<TerminalColors>(*field_colors);
        if (!decoded) return std::move(decoded).error();
        result.colors = std::move(decoded).value();
    }
    const Json* field_cols = value.find("cols");
    if (!field_cols) {
        return make_error(ErrorCode::decode, "missing required field 'cols'");
    }
    if (field_cols) {
        auto decoded = decode_value<std::uint16_t>(*field_cols);
        if (!decoded) return std::move(decoded).error();
        result.cols = std::move(decoded).value();
    }
    const Json* field_data = value.find("data");
    if (field_data) {
        auto decoded = decode_value<Base64>(*field_data);
        if (!decoded) return std::move(decoded).error();
        result.data = std::move(decoded).value();
    }
    const Json* field_kitty_graphics_state = value.find("kitty_graphics_state");
    if (field_kitty_graphics_state) {
        auto decoded = decode_value<KittyGraphicsState>(*field_kitty_graphics_state);
        if (!decoded) return std::move(decoded).error();
        result.kitty_graphics_state = std::move(decoded).value();
    }
    const Json* field_kitty_image_aliases = value.find("kitty_image_aliases");
    if (field_kitty_image_aliases) {
        auto decoded = decode_value<std::vector<KittyImageAlias>>(*field_kitty_image_aliases);
        if (!decoded) return std::move(decoded).error();
        result.kitty_image_aliases = std::move(decoded).value();
    }
    const Json* field_replay = value.find("replay");
    if (field_replay) {
        auto decoded = decode_value<Base64>(*field_replay);
        if (!decoded) return std::move(decoded).error();
        result.replay = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::uint16_t>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("resized"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<ScreenAddedEvent>::encode(const ScreenAddedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("screen-added")));
    auto encoded_entity = encode_value(value.entity);
    if (!encoded_entity) return std::move(encoded_entity).error();
    object.emplace("entity", std::move(encoded_entity).value());
    auto encoded_index = encode_value(value.index);
    if (!encoded_index) return std::move(encoded_index).error();
    object.emplace("index", std::move(encoded_index).value());
    auto encoded_screen = encode_value(value.screen);
    if (!encoded_screen) return std::move(encoded_screen).error();
    object.emplace("screen", std::move(encoded_screen).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    return Json(std::move(object));
}

Result<ScreenAddedEvent> Codec<ScreenAddedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ScreenAddedEvent result{};
    const Json* field_entity = value.find("entity");
    if (!field_entity) {
        return make_error(ErrorCode::decode, "missing required field 'entity'");
    }
    if (field_entity) {
        auto decoded = decode_value<Screen>(*field_entity);
        if (!decoded) return std::move(decoded).error();
        result.entity = std::move(decoded).value();
    }
    const Json* field_index = value.find("index");
    if (!field_index) {
        return make_error(ErrorCode::decode, "missing required field 'index'");
    }
    if (field_index) {
        auto decoded = decode_value<std::uint64_t>(*field_index);
        if (!decoded) return std::move(decoded).error();
        result.index = std::move(decoded).value();
    }
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        auto decoded = decode_value<Id>(*field_screen);
        if (!decoded) return std::move(decoded).error();
        result.screen = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("screen-added"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<ScreenClosedEvent>::encode(const ScreenClosedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("screen-closed")));
    auto encoded_entity = encode_value(value.entity);
    if (!encoded_entity) return std::move(encoded_entity).error();
    object.emplace("entity", std::move(encoded_entity).value());
    auto encoded_index = encode_value(value.index);
    if (!encoded_index) return std::move(encoded_index).error();
    object.emplace("index", std::move(encoded_index).value());
    auto encoded_screen = encode_value(value.screen);
    if (!encoded_screen) return std::move(encoded_screen).error();
    object.emplace("screen", std::move(encoded_screen).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    return Json(std::move(object));
}

Result<ScreenClosedEvent> Codec<ScreenClosedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ScreenClosedEvent result{};
    const Json* field_entity = value.find("entity");
    if (!field_entity) {
        return make_error(ErrorCode::decode, "missing required field 'entity'");
    }
    if (field_entity) {
        auto decoded = decode_value<Screen>(*field_entity);
        if (!decoded) return std::move(decoded).error();
        result.entity = std::move(decoded).value();
    }
    const Json* field_index = value.find("index");
    if (!field_index) {
        return make_error(ErrorCode::decode, "missing required field 'index'");
    }
    if (field_index) {
        auto decoded = decode_value<std::uint64_t>(*field_index);
        if (!decoded) return std::move(decoded).error();
        result.index = std::move(decoded).value();
    }
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        auto decoded = decode_value<Id>(*field_screen);
        if (!decoded) return std::move(decoded).error();
        result.screen = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("screen-closed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<ScreenRenamedEvent>::encode(const ScreenRenamedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("screen-renamed")));
    auto encoded_entity = encode_value(value.entity);
    if (!encoded_entity) return std::move(encoded_entity).error();
    object.emplace("entity", std::move(encoded_entity).value());
    auto encoded_screen = encode_value(value.screen);
    if (!encoded_screen) return std::move(encoded_screen).error();
    object.emplace("screen", std::move(encoded_screen).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    return Json(std::move(object));
}

Result<ScreenRenamedEvent> Codec<ScreenRenamedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ScreenRenamedEvent result{};
    const Json* field_entity = value.find("entity");
    if (!field_entity) {
        return make_error(ErrorCode::decode, "missing required field 'entity'");
    }
    if (field_entity) {
        auto decoded = decode_value<Screen>(*field_entity);
        if (!decoded) return std::move(decoded).error();
        result.entity = std::move(decoded).value();
    }
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        auto decoded = decode_value<Id>(*field_screen);
        if (!decoded) return std::move(decoded).error();
        result.screen = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("screen-renamed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<ScrollChangedEvent>::encode(const ScrollChangedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("scroll-changed")));
    auto encoded_at_bottom = encode_value(value.at_bottom);
    if (!encoded_at_bottom) return std::move(encoded_at_bottom).error();
    object.emplace("at_bottom", std::move(encoded_at_bottom).value());
    auto encoded_offset = encode_value(value.offset);
    if (!encoded_offset) return std::move(encoded_offset).error();
    object.emplace("offset", std::move(encoded_offset).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<ScrollChangedEvent> Codec<ScrollChangedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    ScrollChangedEvent result{};
    const Json* field_at_bottom = value.find("at_bottom");
    if (!field_at_bottom) {
        return make_error(ErrorCode::decode, "missing required field 'at_bottom'");
    }
    if (field_at_bottom) {
        auto decoded = decode_value<bool>(*field_at_bottom);
        if (!decoded) return std::move(decoded).error();
        result.at_bottom = std::move(decoded).value();
    }
    const Json* field_offset = value.find("offset");
    if (!field_offset) {
        return make_error(ErrorCode::decode, "missing required field 'offset'");
    }
    if (field_offset) {
        auto decoded = decode_value<std::uint64_t>(*field_offset);
        if (!decoded) return std::move(decoded).error();
        result.offset = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("scroll-changed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<StatusEvent>::encode(const StatusEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("status")));
    auto encoded_message = encode_value(value.message);
    if (!encoded_message) return std::move(encoded_message).error();
    object.emplace("message", std::move(encoded_message).value());
    return Json(std::move(object));
}

Result<StatusEvent> Codec<StatusEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    StatusEvent result{};
    const Json* field_message = value.find("message");
    if (!field_message) {
        return make_error(ErrorCode::decode, "missing required field 'message'");
    }
    if (field_message) {
        auto decoded = decode_value<std::string>(*field_message);
        if (!decoded) return std::move(decoded).error();
        result.message = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("status"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<SurfaceExitedEvent>::encode(const SurfaceExitedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("surface-exited")));
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<SurfaceExitedEvent> Codec<SurfaceExitedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SurfaceExitedEvent result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("surface-exited"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<SurfaceOutputEvent>::encode(const SurfaceOutputEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("surface-output")));
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<SurfaceOutputEvent> Codec<SurfaceOutputEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SurfaceOutputEvent result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("surface-output"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<SurfaceResizeFailedEvent>::encode(const SurfaceResizeFailedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("surface-resize-failed")));
    auto encoded_cols = encode_value(value.cols);
    if (!encoded_cols) return std::move(encoded_cols).error();
    object.emplace("cols", std::move(encoded_cols).value());
    auto encoded_error = encode_value(value.error);
    if (!encoded_error) return std::move(encoded_error).error();
    object.emplace("error", std::move(encoded_error).value());
    if (value.reservation_id) {
        auto encoded = encode_value(*value.reservation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("reservation_id", std::move(encoded).value());
    } else {
        object.emplace("reservation_id", Json(nullptr));
    }
    if (value.retry_after_ms) {
        auto encoded = encode_value(*value.retry_after_ms);
        if (!encoded) return std::move(encoded).error();
        object.emplace("retry_after_ms", std::move(encoded).value());
    } else {
        object.emplace("retry_after_ms", Json(nullptr));
    }
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<SurfaceResizeFailedEvent> Codec<SurfaceResizeFailedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SurfaceResizeFailedEvent result{};
    const Json* field_cols = value.find("cols");
    if (!field_cols) {
        return make_error(ErrorCode::decode, "missing required field 'cols'");
    }
    if (field_cols) {
        auto decoded = decode_value<std::uint16_t>(*field_cols);
        if (!decoded) return std::move(decoded).error();
        result.cols = std::move(decoded).value();
    }
    const Json* field_error = value.find("error");
    if (!field_error) {
        return make_error(ErrorCode::decode, "missing required field 'error'");
    }
    if (field_error) {
        auto decoded = decode_value<std::string>(*field_error);
        if (!decoded) return std::move(decoded).error();
        result.error = std::move(decoded).value();
    }
    const Json* field_reservation_id = value.find("reservation_id");
    if (!field_reservation_id) {
        return make_error(ErrorCode::decode, "missing required field 'reservation_id'");
    }
    if (field_reservation_id) {
        if (field_reservation_id->is_null()) {
            result.reservation_id.reset();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_reservation_id);
            if (!decoded) return std::move(decoded).error();
            result.reservation_id = std::move(decoded).value();
        }
    }
    const Json* field_retry_after_ms = value.find("retry_after_ms");
    if (!field_retry_after_ms) {
        return make_error(ErrorCode::decode, "missing required field 'retry_after_ms'");
    }
    if (field_retry_after_ms) {
        if (field_retry_after_ms->is_null()) {
            result.retry_after_ms.reset();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_retry_after_ms);
            if (!decoded) return std::move(decoded).error();
            result.retry_after_ms = std::move(decoded).value();
        }
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::uint16_t>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("surface-resize-failed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<SurfaceResizedEvent>::encode(const SurfaceResizedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("surface-resized")));
    auto encoded_cols = encode_value(value.cols);
    if (!encoded_cols) return std::move(encoded_cols).error();
    object.emplace("cols", std::move(encoded_cols).value());
    if (value.reservation_id) {
        auto encoded = encode_value(*value.reservation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("reservation_id", std::move(encoded).value());
    } else {
        object.emplace("reservation_id", Json(nullptr));
    }
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<SurfaceResizedEvent> Codec<SurfaceResizedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    SurfaceResizedEvent result{};
    const Json* field_cols = value.find("cols");
    if (!field_cols) {
        return make_error(ErrorCode::decode, "missing required field 'cols'");
    }
    if (field_cols) {
        auto decoded = decode_value<std::uint16_t>(*field_cols);
        if (!decoded) return std::move(decoded).error();
        result.cols = std::move(decoded).value();
    }
    const Json* field_reservation_id = value.find("reservation_id");
    if (!field_reservation_id) {
        return make_error(ErrorCode::decode, "missing required field 'reservation_id'");
    }
    if (field_reservation_id) {
        if (field_reservation_id->is_null()) {
            result.reservation_id.reset();
        } else {
            auto decoded = decode_value<std::uint64_t>(*field_reservation_id);
            if (!decoded) return std::move(decoded).error();
            result.reservation_id = std::move(decoded).value();
        }
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::uint16_t>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("surface-resized"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<TabAddedEvent>::encode(const TabAddedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("tab-added")));
    auto encoded_entity = encode_value(value.entity);
    if (!encoded_entity) return std::move(encoded_entity).error();
    object.emplace("entity", std::move(encoded_entity).value());
    auto encoded_index = encode_value(value.index);
    if (!encoded_index) return std::move(encoded_index).error();
    object.emplace("index", std::move(encoded_index).value());
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    auto encoded_screen = encode_value(value.screen);
    if (!encoded_screen) return std::move(encoded_screen).error();
    object.emplace("screen", std::move(encoded_screen).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    return Json(std::move(object));
}

Result<TabAddedEvent> Codec<TabAddedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TabAddedEvent result{};
    const Json* field_entity = value.find("entity");
    if (!field_entity) {
        return make_error(ErrorCode::decode, "missing required field 'entity'");
    }
    if (field_entity) {
        auto decoded = decode_value<Tab>(*field_entity);
        if (!decoded) return std::move(decoded).error();
        result.entity = std::move(decoded).value();
    }
    const Json* field_index = value.find("index");
    if (!field_index) {
        return make_error(ErrorCode::decode, "missing required field 'index'");
    }
    if (field_index) {
        auto decoded = decode_value<std::uint64_t>(*field_index);
        if (!decoded) return std::move(decoded).error();
        result.index = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        auto decoded = decode_value<Id>(*field_screen);
        if (!decoded) return std::move(decoded).error();
        result.screen = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("tab-added"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<TabClosedEvent>::encode(const TabClosedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("tab-closed")));
    auto encoded_entity = encode_value(value.entity);
    if (!encoded_entity) return std::move(encoded_entity).error();
    object.emplace("entity", std::move(encoded_entity).value());
    auto encoded_index = encode_value(value.index);
    if (!encoded_index) return std::move(encoded_index).error();
    object.emplace("index", std::move(encoded_index).value());
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    auto encoded_screen = encode_value(value.screen);
    if (!encoded_screen) return std::move(encoded_screen).error();
    object.emplace("screen", std::move(encoded_screen).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    return Json(std::move(object));
}

Result<TabClosedEvent> Codec<TabClosedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TabClosedEvent result{};
    const Json* field_entity = value.find("entity");
    if (!field_entity) {
        return make_error(ErrorCode::decode, "missing required field 'entity'");
    }
    if (field_entity) {
        auto decoded = decode_value<Tab>(*field_entity);
        if (!decoded) return std::move(decoded).error();
        result.entity = std::move(decoded).value();
    }
    const Json* field_index = value.find("index");
    if (!field_index) {
        return make_error(ErrorCode::decode, "missing required field 'index'");
    }
    if (field_index) {
        auto decoded = decode_value<std::uint64_t>(*field_index);
        if (!decoded) return std::move(decoded).error();
        result.index = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        auto decoded = decode_value<Id>(*field_screen);
        if (!decoded) return std::move(decoded).error();
        result.screen = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("tab-closed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<TabRenamedEvent>::encode(const TabRenamedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("tab-renamed")));
    auto encoded_entity = encode_value(value.entity);
    if (!encoded_entity) return std::move(encoded_entity).error();
    object.emplace("entity", std::move(encoded_entity).value());
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    auto encoded_screen = encode_value(value.screen);
    if (!encoded_screen) return std::move(encoded_screen).error();
    object.emplace("screen", std::move(encoded_screen).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    return Json(std::move(object));
}

Result<TabRenamedEvent> Codec<TabRenamedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TabRenamedEvent result{};
    const Json* field_entity = value.find("entity");
    if (!field_entity) {
        return make_error(ErrorCode::decode, "missing required field 'entity'");
    }
    if (field_entity) {
        auto decoded = decode_value<Tab>(*field_entity);
        if (!decoded) return std::move(decoded).error();
        result.entity = std::move(decoded).value();
    }
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_screen = value.find("screen");
    if (!field_screen) {
        return make_error(ErrorCode::decode, "missing required field 'screen'");
    }
    if (field_screen) {
        auto decoded = decode_value<Id>(*field_screen);
        if (!decoded) return std::move(decoded).error();
        result.screen = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("tab-renamed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<TerminalRegistryChangedEvent>::encode(const TerminalRegistryChangedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("terminal-registry-changed")));
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    object.emplace("refetch", Json(std::string("terminal-events-or-list-terminals")));
    auto encoded_registry_id = encode_value(value.registry_id);
    if (!encoded_registry_id) return std::move(encoded_registry_id).error();
    object.emplace("registry_id", std::move(encoded_registry_id).value());
    auto encoded_terminal_revision = encode_value(value.terminal_revision);
    if (!encoded_terminal_revision) return std::move(encoded_terminal_revision).error();
    object.emplace("terminal_revision", std::move(encoded_terminal_revision).value());
    return Json(std::move(object));
}

Result<TerminalRegistryChangedEvent> Codec<TerminalRegistryChangedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TerminalRegistryChangedEvent result{};
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_refetch = value.find("refetch");
    if (!field_refetch) {
        return make_error(ErrorCode::decode, "missing required field 'refetch'");
    }
    if (field_refetch) {
        if (*field_refetch != Json(std::string("terminal-events-or-list-terminals"))) {
            return make_error(ErrorCode::decode, "field 'refetch' has the wrong literal value");
        }
    }
    const Json* field_registry_id = value.find("registry_id");
    if (!field_registry_id) {
        return make_error(ErrorCode::decode, "missing required field 'registry_id'");
    }
    if (field_registry_id) {
        auto decoded = decode_value<std::string>(*field_registry_id);
        if (!decoded) return std::move(decoded).error();
        result.registry_id = std::move(decoded).value();
    }
    const Json* field_terminal_revision = value.find("terminal_revision");
    if (!field_terminal_revision) {
        return make_error(ErrorCode::decode, "missing required field 'terminal_revision'");
    }
    if (field_terminal_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_terminal_revision);
        if (!decoded) return std::move(decoded).error();
        result.terminal_revision = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("terminal-registry-changed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<TitleChangedEvent>::encode(const TitleChangedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("title-changed")));
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    if (value.title) {
        auto encoded = encode_value(*value.title);
        if (!encoded) return std::move(encoded).error();
        object.emplace("title", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<TitleChangedEvent> Codec<TitleChangedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TitleChangedEvent result{};
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_title = value.find("title");
    if (field_title) {
        auto decoded = decode_value<std::string>(*field_title);
        if (!decoded) return std::move(decoded).error();
        result.title = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("title-changed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<TreeChangedEvent>::encode(const TreeChangedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("tree-changed")));
    return Json(std::move(object));
}

Result<TreeChangedEvent> Codec<TreeChangedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TreeChangedEvent result{};
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("tree-changed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<VtStateEvent>::encode(const VtStateEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("vt-state")));
    if (value.colors) {
        auto encoded = encode_value(*value.colors);
        if (!encoded) return std::move(encoded).error();
        object.emplace("colors", std::move(encoded).value());
    }
    auto encoded_cols = encode_value(value.cols);
    if (!encoded_cols) return std::move(encoded_cols).error();
    object.emplace("cols", std::move(encoded_cols).value());
    auto encoded_data = encode_value(value.data);
    if (!encoded_data) return std::move(encoded_data).error();
    object.emplace("data", std::move(encoded_data).value());
    if (value.kitty_graphics_state) {
        auto encoded = encode_value(*value.kitty_graphics_state);
        if (!encoded) return std::move(encoded).error();
        object.emplace("kitty_graphics_state", std::move(encoded).value());
    }
    if (value.kitty_image_aliases) {
        auto encoded = encode_value(*value.kitty_image_aliases);
        if (!encoded) return std::move(encoded).error();
        object.emplace("kitty_image_aliases", std::move(encoded).value());
    }
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    auto encoded_surface = encode_value(value.surface);
    if (!encoded_surface) return std::move(encoded_surface).error();
    object.emplace("surface", std::move(encoded_surface).value());
    return Json(std::move(object));
}

Result<VtStateEvent> Codec<VtStateEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    VtStateEvent result{};
    const Json* field_colors = value.find("colors");
    if (field_colors) {
        auto decoded = decode_value<TerminalColors>(*field_colors);
        if (!decoded) return std::move(decoded).error();
        result.colors = std::move(decoded).value();
    }
    const Json* field_cols = value.find("cols");
    if (!field_cols) {
        return make_error(ErrorCode::decode, "missing required field 'cols'");
    }
    if (field_cols) {
        auto decoded = decode_value<std::uint16_t>(*field_cols);
        if (!decoded) return std::move(decoded).error();
        result.cols = std::move(decoded).value();
    }
    const Json* field_data = value.find("data");
    if (!field_data) {
        return make_error(ErrorCode::decode, "missing required field 'data'");
    }
    if (field_data) {
        auto decoded = decode_value<Base64>(*field_data);
        if (!decoded) return std::move(decoded).error();
        result.data = std::move(decoded).value();
    }
    const Json* field_kitty_graphics_state = value.find("kitty_graphics_state");
    if (field_kitty_graphics_state) {
        auto decoded = decode_value<KittyGraphicsState>(*field_kitty_graphics_state);
        if (!decoded) return std::move(decoded).error();
        result.kitty_graphics_state = std::move(decoded).value();
    }
    const Json* field_kitty_image_aliases = value.find("kitty_image_aliases");
    if (field_kitty_image_aliases) {
        auto decoded = decode_value<std::vector<KittyImageAlias>>(*field_kitty_image_aliases);
        if (!decoded) return std::move(decoded).error();
        result.kitty_image_aliases = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::uint16_t>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    const Json* field_surface = value.find("surface");
    if (!field_surface) {
        return make_error(ErrorCode::decode, "missing required field 'surface'");
    }
    if (field_surface) {
        auto decoded = decode_value<Id>(*field_surface);
        if (!decoded) return std::move(decoded).error();
        result.surface = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("vt-state"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<WindowTitleRequestedEvent>::encode(const WindowTitleRequestedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("window-title-requested")));
    auto encoded_title = encode_value(value.title);
    if (!encoded_title) return std::move(encoded_title).error();
    object.emplace("title", std::move(encoded_title).value());
    return Json(std::move(object));
}

Result<WindowTitleRequestedEvent> Codec<WindowTitleRequestedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    WindowTitleRequestedEvent result{};
    const Json* field_title = value.find("title");
    if (!field_title) {
        return make_error(ErrorCode::decode, "missing required field 'title'");
    }
    if (field_title) {
        auto decoded = decode_value<std::string>(*field_title);
        if (!decoded) return std::move(decoded).error();
        result.title = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("window-title-requested"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<WorkspaceAddedEvent>::encode(const WorkspaceAddedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("workspace-added")));
    auto encoded_entity = encode_value(value.entity);
    if (!encoded_entity) return std::move(encoded_entity).error();
    object.emplace("entity", std::move(encoded_entity).value());
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    auto encoded_index = encode_value(value.index);
    if (!encoded_index) return std::move(encoded_index).error();
    object.emplace("index", std::move(encoded_index).value());
    if (value.mutation_id) {
        auto encoded = encode_value(*value.mutation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("mutation_id", std::move(encoded).value());
    }
    if (value.origin) {
        auto encoded = encode_value(*value.origin);
        if (!encoded) return std::move(encoded).error();
        object.emplace("origin", std::move(encoded).value());
    }
    auto encoded_registry_id = encode_value(value.registry_id);
    if (!encoded_registry_id) return std::move(encoded_registry_id).error();
    object.emplace("registry_id", std::move(encoded_registry_id).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    auto encoded_workspace_revision = encode_value(value.workspace_revision);
    if (!encoded_workspace_revision) return std::move(encoded_workspace_revision).error();
    object.emplace("workspace_revision", std::move(encoded_workspace_revision).value());
    return Json(std::move(object));
}

Result<WorkspaceAddedEvent> Codec<WorkspaceAddedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    WorkspaceAddedEvent result{};
    const Json* field_entity = value.find("entity");
    if (!field_entity) {
        return make_error(ErrorCode::decode, "missing required field 'entity'");
    }
    if (field_entity) {
        auto decoded = decode_value<Workspace>(*field_entity);
        if (!decoded) return std::move(decoded).error();
        result.entity = std::move(decoded).value();
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_index = value.find("index");
    if (!field_index) {
        return make_error(ErrorCode::decode, "missing required field 'index'");
    }
    if (field_index) {
        auto decoded = decode_value<std::uint64_t>(*field_index);
        if (!decoded) return std::move(decoded).error();
        result.index = std::move(decoded).value();
    }
    const Json* field_mutation_id = value.find("mutation_id");
    if (field_mutation_id) {
        auto decoded = decode_value<std::string>(*field_mutation_id);
        if (!decoded) return std::move(decoded).error();
        result.mutation_id = std::move(decoded).value();
    }
    const Json* field_origin = value.find("origin");
    if (field_origin) {
        auto decoded = decode_value<std::string>(*field_origin);
        if (!decoded) return std::move(decoded).error();
        result.origin = std::move(decoded).value();
    }
    const Json* field_registry_id = value.find("registry_id");
    if (!field_registry_id) {
        return make_error(ErrorCode::decode, "missing required field 'registry_id'");
    }
    if (field_registry_id) {
        auto decoded = decode_value<std::string>(*field_registry_id);
        if (!decoded) return std::move(decoded).error();
        result.registry_id = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    const Json* field_workspace_revision = value.find("workspace_revision");
    if (!field_workspace_revision) {
        return make_error(ErrorCode::decode, "missing required field 'workspace_revision'");
    }
    if (field_workspace_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_workspace_revision);
        if (!decoded) return std::move(decoded).error();
        result.workspace_revision = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("workspace-added"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<WorkspaceClosedEvent>::encode(const WorkspaceClosedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("workspace-closed")));
    auto encoded_entity = encode_value(value.entity);
    if (!encoded_entity) return std::move(encoded_entity).error();
    object.emplace("entity", std::move(encoded_entity).value());
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    auto encoded_index = encode_value(value.index);
    if (!encoded_index) return std::move(encoded_index).error();
    object.emplace("index", std::move(encoded_index).value());
    if (value.mutation_id) {
        auto encoded = encode_value(*value.mutation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("mutation_id", std::move(encoded).value());
    }
    if (value.origin) {
        auto encoded = encode_value(*value.origin);
        if (!encoded) return std::move(encoded).error();
        object.emplace("origin", std::move(encoded).value());
    }
    auto encoded_registry_id = encode_value(value.registry_id);
    if (!encoded_registry_id) return std::move(encoded_registry_id).error();
    object.emplace("registry_id", std::move(encoded_registry_id).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    auto encoded_workspace_revision = encode_value(value.workspace_revision);
    if (!encoded_workspace_revision) return std::move(encoded_workspace_revision).error();
    object.emplace("workspace_revision", std::move(encoded_workspace_revision).value());
    return Json(std::move(object));
}

Result<WorkspaceClosedEvent> Codec<WorkspaceClosedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    WorkspaceClosedEvent result{};
    const Json* field_entity = value.find("entity");
    if (!field_entity) {
        return make_error(ErrorCode::decode, "missing required field 'entity'");
    }
    if (field_entity) {
        auto decoded = decode_value<Workspace>(*field_entity);
        if (!decoded) return std::move(decoded).error();
        result.entity = std::move(decoded).value();
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_index = value.find("index");
    if (!field_index) {
        return make_error(ErrorCode::decode, "missing required field 'index'");
    }
    if (field_index) {
        auto decoded = decode_value<std::uint64_t>(*field_index);
        if (!decoded) return std::move(decoded).error();
        result.index = std::move(decoded).value();
    }
    const Json* field_mutation_id = value.find("mutation_id");
    if (field_mutation_id) {
        auto decoded = decode_value<std::string>(*field_mutation_id);
        if (!decoded) return std::move(decoded).error();
        result.mutation_id = std::move(decoded).value();
    }
    const Json* field_origin = value.find("origin");
    if (field_origin) {
        auto decoded = decode_value<std::string>(*field_origin);
        if (!decoded) return std::move(decoded).error();
        result.origin = std::move(decoded).value();
    }
    const Json* field_registry_id = value.find("registry_id");
    if (!field_registry_id) {
        return make_error(ErrorCode::decode, "missing required field 'registry_id'");
    }
    if (field_registry_id) {
        auto decoded = decode_value<std::string>(*field_registry_id);
        if (!decoded) return std::move(decoded).error();
        result.registry_id = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    const Json* field_workspace_revision = value.find("workspace_revision");
    if (!field_workspace_revision) {
        return make_error(ErrorCode::decode, "missing required field 'workspace_revision'");
    }
    if (field_workspace_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_workspace_revision);
        if (!decoded) return std::move(decoded).error();
        result.workspace_revision = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("workspace-closed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<WorkspaceMovedEvent>::encode(const WorkspaceMovedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("workspace-moved")));
    auto encoded_entity = encode_value(value.entity);
    if (!encoded_entity) return std::move(encoded_entity).error();
    object.emplace("entity", std::move(encoded_entity).value());
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    auto encoded_index = encode_value(value.index);
    if (!encoded_index) return std::move(encoded_index).error();
    object.emplace("index", std::move(encoded_index).value());
    if (value.mutation_id) {
        auto encoded = encode_value(*value.mutation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("mutation_id", std::move(encoded).value());
    }
    if (value.origin) {
        auto encoded = encode_value(*value.origin);
        if (!encoded) return std::move(encoded).error();
        object.emplace("origin", std::move(encoded).value());
    }
    auto encoded_registry_id = encode_value(value.registry_id);
    if (!encoded_registry_id) return std::move(encoded_registry_id).error();
    object.emplace("registry_id", std::move(encoded_registry_id).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    auto encoded_workspace_revision = encode_value(value.workspace_revision);
    if (!encoded_workspace_revision) return std::move(encoded_workspace_revision).error();
    object.emplace("workspace_revision", std::move(encoded_workspace_revision).value());
    return Json(std::move(object));
}

Result<WorkspaceMovedEvent> Codec<WorkspaceMovedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    WorkspaceMovedEvent result{};
    const Json* field_entity = value.find("entity");
    if (!field_entity) {
        return make_error(ErrorCode::decode, "missing required field 'entity'");
    }
    if (field_entity) {
        auto decoded = decode_value<Workspace>(*field_entity);
        if (!decoded) return std::move(decoded).error();
        result.entity = std::move(decoded).value();
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_index = value.find("index");
    if (!field_index) {
        return make_error(ErrorCode::decode, "missing required field 'index'");
    }
    if (field_index) {
        auto decoded = decode_value<std::uint64_t>(*field_index);
        if (!decoded) return std::move(decoded).error();
        result.index = std::move(decoded).value();
    }
    const Json* field_mutation_id = value.find("mutation_id");
    if (field_mutation_id) {
        auto decoded = decode_value<std::string>(*field_mutation_id);
        if (!decoded) return std::move(decoded).error();
        result.mutation_id = std::move(decoded).value();
    }
    const Json* field_origin = value.find("origin");
    if (field_origin) {
        auto decoded = decode_value<std::string>(*field_origin);
        if (!decoded) return std::move(decoded).error();
        result.origin = std::move(decoded).value();
    }
    const Json* field_registry_id = value.find("registry_id");
    if (!field_registry_id) {
        return make_error(ErrorCode::decode, "missing required field 'registry_id'");
    }
    if (field_registry_id) {
        auto decoded = decode_value<std::string>(*field_registry_id);
        if (!decoded) return std::move(decoded).error();
        result.registry_id = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    const Json* field_workspace_revision = value.find("workspace_revision");
    if (!field_workspace_revision) {
        return make_error(ErrorCode::decode, "missing required field 'workspace_revision'");
    }
    if (field_workspace_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_workspace_revision);
        if (!decoded) return std::move(decoded).error();
        result.workspace_revision = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("workspace-moved"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<WorkspaceRenamedEvent>::encode(const WorkspaceRenamedEvent& value) {
    (void)value;
    Json::Object object;
    object.emplace("event", Json(std::string("workspace-renamed")));
    auto encoded_entity = encode_value(value.entity);
    if (!encoded_entity) return std::move(encoded_entity).error();
    object.emplace("entity", std::move(encoded_entity).value());
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    if (value.mutation_id) {
        auto encoded = encode_value(*value.mutation_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("mutation_id", std::move(encoded).value());
    }
    if (value.origin) {
        auto encoded = encode_value(*value.origin);
        if (!encoded) return std::move(encoded).error();
        object.emplace("origin", std::move(encoded).value());
    }
    auto encoded_registry_id = encode_value(value.registry_id);
    if (!encoded_registry_id) return std::move(encoded_registry_id).error();
    object.emplace("registry_id", std::move(encoded_registry_id).value());
    auto encoded_workspace = encode_value(value.workspace);
    if (!encoded_workspace) return std::move(encoded_workspace).error();
    object.emplace("workspace", std::move(encoded_workspace).value());
    auto encoded_workspace_revision = encode_value(value.workspace_revision);
    if (!encoded_workspace_revision) return std::move(encoded_workspace_revision).error();
    object.emplace("workspace_revision", std::move(encoded_workspace_revision).value());
    return Json(std::move(object));
}

Result<WorkspaceRenamedEvent> Codec<WorkspaceRenamedEvent>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    WorkspaceRenamedEvent result{};
    const Json* field_entity = value.find("entity");
    if (!field_entity) {
        return make_error(ErrorCode::decode, "missing required field 'entity'");
    }
    if (field_entity) {
        auto decoded = decode_value<Workspace>(*field_entity);
        if (!decoded) return std::move(decoded).error();
        result.entity = std::move(decoded).value();
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_mutation_id = value.find("mutation_id");
    if (field_mutation_id) {
        auto decoded = decode_value<std::string>(*field_mutation_id);
        if (!decoded) return std::move(decoded).error();
        result.mutation_id = std::move(decoded).value();
    }
    const Json* field_origin = value.find("origin");
    if (field_origin) {
        auto decoded = decode_value<std::string>(*field_origin);
        if (!decoded) return std::move(decoded).error();
        result.origin = std::move(decoded).value();
    }
    const Json* field_registry_id = value.find("registry_id");
    if (!field_registry_id) {
        return make_error(ErrorCode::decode, "missing required field 'registry_id'");
    }
    if (field_registry_id) {
        auto decoded = decode_value<std::string>(*field_registry_id);
        if (!decoded) return std::move(decoded).error();
        result.registry_id = std::move(decoded).value();
    }
    const Json* field_workspace = value.find("workspace");
    if (!field_workspace) {
        return make_error(ErrorCode::decode, "missing required field 'workspace'");
    }
    if (field_workspace) {
        auto decoded = decode_value<Id>(*field_workspace);
        if (!decoded) return std::move(decoded).error();
        result.workspace = std::move(decoded).value();
    }
    const Json* field_workspace_revision = value.find("workspace_revision");
    if (!field_workspace_revision) {
        return make_error(ErrorCode::decode, "missing required field 'workspace_revision'");
    }
    if (field_workspace_revision) {
        auto decoded = decode_value<std::uint64_t>(*field_workspace_revision);
        if (!decoded) return std::move(decoded).error();
        result.workspace_revision = std::move(decoded).value();
    }
    const Json* field_event = value.find("event");
    if (!field_event) {
        return make_error(ErrorCode::decode, "missing required field 'event'");
    }
    if (field_event) {
        if (*field_event != Json(std::string("workspace-renamed"))) {
            return make_error(ErrorCode::decode, "field 'event' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<CopyResultMode>::encode(const CopyResultMode& value) {
    switch (value) {
        case CopyResultMode::screen: return Json(std::string("screen"));
        case CopyResultMode::selection: return Json(std::string("selection"));
        case CopyResultMode::scrollback: return Json(std::string("scrollback"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<CopyResultMode> Codec<CopyResultMode>::decode(const Json& value) {
    if (value == Json(std::string("screen"))) return CopyResultMode::screen;
    if (value == Json(std::string("selection"))) return CopyResultMode::selection;
    if (value == Json(std::string("scrollback"))) return CopyResultMode::scrollback;
    return make_error(ErrorCode::decode, "unknown CopyResultMode value");
}

Result<Json> Codec<DeclarativeLayoutLeaf>::encode(const DeclarativeLayoutLeaf& value) {
    (void)value;
    Json::Object object;
    object.emplace("type", Json(std::string("leaf")));
    if (!value.command.is_absent()) {
        auto encoded = encode_value(value.command);
        if (!encoded) return std::move(encoded).error();
        object.emplace("command", std::move(encoded).value());
    }
    if (!value.cwd.is_absent()) {
        auto encoded = encode_value(value.cwd);
        if (!encoded) return std::move(encoded).error();
        object.emplace("cwd", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<DeclarativeLayoutLeaf> Codec<DeclarativeLayoutLeaf>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    DeclarativeLayoutLeaf result{};
    const Json* field_command = value.find("command");
    if (field_command) {
        if (field_command->is_null()) {
            result.command = Field<std::vector<std::string>>::null();
        } else {
            auto decoded = decode_value<std::vector<std::string>>(*field_command);
            if (!decoded) return std::move(decoded).error();
            result.command = Field<std::vector<std::string>>(std::move(decoded).value());
        }
    }
    const Json* field_cwd = value.find("cwd");
    if (field_cwd) {
        if (field_cwd->is_null()) {
            result.cwd = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_cwd);
            if (!decoded) return std::move(decoded).error();
            result.cwd = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_type = value.find("type");
    if (!field_type) {
        return make_error(ErrorCode::decode, "missing required field 'type'");
    }
    if (field_type) {
        if (*field_type != Json(std::string("leaf"))) {
            return make_error(ErrorCode::decode, "field 'type' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<DeclarativeLayoutSplit>::encode(const DeclarativeLayoutSplit& value) {
    (void)value;
    Json::Object object;
    object.emplace("type", Json(std::string("split")));
    auto encoded_a = encode_value(value.a);
    if (!encoded_a) return std::move(encoded_a).error();
    object.emplace("a", std::move(encoded_a).value());
    auto encoded_b = encode_value(value.b);
    if (!encoded_b) return std::move(encoded_b).error();
    object.emplace("b", std::move(encoded_b).value());
    auto encoded_dir = encode_value(value.dir);
    if (!encoded_dir) return std::move(encoded_dir).error();
    object.emplace("dir", std::move(encoded_dir).value());
    auto encoded_ratio = encode_value(value.ratio);
    if (!encoded_ratio) return std::move(encoded_ratio).error();
    object.emplace("ratio", std::move(encoded_ratio).value());
    return Json(std::move(object));
}

Result<DeclarativeLayoutSplit> Codec<DeclarativeLayoutSplit>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    DeclarativeLayoutSplit result{};
    const Json* field_a = value.find("a");
    if (!field_a) {
        return make_error(ErrorCode::decode, "missing required field 'a'");
    }
    if (field_a) {
        auto decoded = decode_value<std::shared_ptr<DeclarativeLayout>>(*field_a);
        if (!decoded) return std::move(decoded).error();
        result.a = std::move(decoded).value();
    }
    const Json* field_b = value.find("b");
    if (!field_b) {
        return make_error(ErrorCode::decode, "missing required field 'b'");
    }
    if (field_b) {
        auto decoded = decode_value<std::shared_ptr<DeclarativeLayout>>(*field_b);
        if (!decoded) return std::move(decoded).error();
        result.b = std::move(decoded).value();
    }
    const Json* field_dir = value.find("dir");
    if (!field_dir) {
        return make_error(ErrorCode::decode, "missing required field 'dir'");
    }
    if (field_dir) {
        auto decoded = decode_value<SplitDirection>(*field_dir);
        if (!decoded) return std::move(decoded).error();
        result.dir = std::move(decoded).value();
    }
    const Json* field_ratio = value.find("ratio");
    if (!field_ratio) {
        return make_error(ErrorCode::decode, "missing required field 'ratio'");
    }
    if (field_ratio) {
        auto decoded = decode_value<float>(*field_ratio);
        if (!decoded) return std::move(decoded).error();
        result.ratio = std::move(decoded).value();
    }
    const Json* field_type = value.find("type");
    if (!field_type) {
        return make_error(ErrorCode::decode, "missing required field 'type'");
    }
    if (field_type) {
        if (*field_type != Json(std::string("split"))) {
            return make_error(ErrorCode::decode, "field 'type' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<DeclarativeLayoutStack>::encode(const DeclarativeLayoutStack& value) {
    (void)value;
    Json::Object object;
    object.emplace("type", Json(std::string("stack")));
    auto encoded_expanded = encode_value(value.expanded);
    if (!encoded_expanded) return std::move(encoded_expanded).error();
    object.emplace("expanded", std::move(encoded_expanded).value());
    auto encoded_panes = encode_value(value.panes);
    if (!encoded_panes) return std::move(encoded_panes).error();
    object.emplace("panes", std::move(encoded_panes).value());
    return Json(std::move(object));
}

Result<DeclarativeLayoutStack> Codec<DeclarativeLayoutStack>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    DeclarativeLayoutStack result{};
    const Json* field_expanded = value.find("expanded");
    if (!field_expanded) {
        return make_error(ErrorCode::decode, "missing required field 'expanded'");
    }
    if (field_expanded) {
        auto decoded = decode_value<Id>(*field_expanded);
        if (!decoded) return std::move(decoded).error();
        result.expanded = std::move(decoded).value();
    }
    const Json* field_panes = value.find("panes");
    if (!field_panes) {
        return make_error(ErrorCode::decode, "missing required field 'panes'");
    }
    if (field_panes) {
        auto decoded = decode_value<std::vector<Id>>(*field_panes);
        if (!decoded) return std::move(decoded).error();
        result.panes = std::move(decoded).value();
    }
    const Json* field_type = value.find("type");
    if (!field_type) {
        return make_error(ErrorCode::decode, "missing required field 'type'");
    }
    if (field_type) {
        if (*field_type != Json(std::string("stack"))) {
            return make_error(ErrorCode::decode, "field 'type' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<FrontendJournalEventFocus>::encode(const FrontendJournalEventFocus& value) {
    (void)value;
    Json::Object object;
    object.emplace("kind", Json(std::string("focus")));
    if (!value.content_id.is_absent()) {
        auto encoded = encode_value(value.content_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("content_id", std::move(encoded).value());
    }
    auto encoded_event_id = encode_value(value.event_id);
    if (!encoded_event_id) return std::move(encoded_event_id).error();
    object.emplace("event_id", std::move(encoded_event_id).value());
    auto encoded_frontend_projection_id = encode_value(value.frontend_projection_id);
    if (!encoded_frontend_projection_id) return std::move(encoded_frontend_projection_id).error();
    object.emplace("frontend_projection_id", std::move(encoded_frontend_projection_id).value());
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    if (!value.pane_id.is_absent()) {
        auto encoded = encode_value(value.pane_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("pane_id", std::move(encoded).value());
    }
    if (!value.screen_id.is_absent()) {
        auto encoded = encode_value(value.screen_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("screen_id", std::move(encoded).value());
    }
    if (!value.tab_id.is_absent()) {
        auto encoded = encode_value(value.tab_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("tab_id", std::move(encoded).value());
    }
    auto encoded_target = encode_value(value.target);
    if (!encoded_target) return std::move(encoded_target).error();
    object.emplace("target", std::move(encoded_target).value());
    if (!value.workspace_id.is_absent()) {
        auto encoded = encode_value(value.workspace_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("workspace_id", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<FrontendJournalEventFocus> Codec<FrontendJournalEventFocus>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    FrontendJournalEventFocus result{};
    const Json* field_content_id = value.find("content_id");
    if (field_content_id) {
        if (field_content_id->is_null()) {
            result.content_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_content_id);
            if (!decoded) return std::move(decoded).error();
            result.content_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_event_id = value.find("event_id");
    if (!field_event_id) {
        return make_error(ErrorCode::decode, "missing required field 'event_id'");
    }
    if (field_event_id) {
        auto decoded = decode_value<std::string>(*field_event_id);
        if (!decoded) return std::move(decoded).error();
        result.event_id = std::move(decoded).value();
    }
    const Json* field_frontend_projection_id = value.find("frontend_projection_id");
    if (!field_frontend_projection_id) {
        return make_error(ErrorCode::decode, "missing required field 'frontend_projection_id'");
    }
    if (field_frontend_projection_id) {
        auto decoded = decode_value<std::string>(*field_frontend_projection_id);
        if (!decoded) return std::move(decoded).error();
        result.frontend_projection_id = std::move(decoded).value();
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_pane_id = value.find("pane_id");
    if (field_pane_id) {
        if (field_pane_id->is_null()) {
            result.pane_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_pane_id);
            if (!decoded) return std::move(decoded).error();
            result.pane_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_screen_id = value.find("screen_id");
    if (field_screen_id) {
        if (field_screen_id->is_null()) {
            result.screen_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_screen_id);
            if (!decoded) return std::move(decoded).error();
            result.screen_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_tab_id = value.find("tab_id");
    if (field_tab_id) {
        if (field_tab_id->is_null()) {
            result.tab_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_tab_id);
            if (!decoded) return std::move(decoded).error();
            result.tab_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_target = value.find("target");
    if (!field_target) {
        return make_error(ErrorCode::decode, "missing required field 'target'");
    }
    if (field_target) {
        auto decoded = decode_value<FrontendFocusTarget>(*field_target);
        if (!decoded) return std::move(decoded).error();
        result.target = std::move(decoded).value();
    }
    const Json* field_workspace_id = value.find("workspace_id");
    if (field_workspace_id) {
        if (field_workspace_id->is_null()) {
            result.workspace_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_workspace_id);
            if (!decoded) return std::move(decoded).error();
            result.workspace_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        if (*field_kind != Json(std::string("focus"))) {
            return make_error(ErrorCode::decode, "field 'kind' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<FrontendJournalEventResize>::encode(const FrontendJournalEventResize& value) {
    (void)value;
    Json::Object object;
    object.emplace("kind", Json(std::string("resize")));
    auto encoded_cell_height = encode_value(value.cell_height);
    if (!encoded_cell_height) return std::move(encoded_cell_height).error();
    object.emplace("cell_height", std::move(encoded_cell_height).value());
    auto encoded_cell_width = encode_value(value.cell_width);
    if (!encoded_cell_width) return std::move(encoded_cell_width).error();
    object.emplace("cell_width", std::move(encoded_cell_width).value());
    auto encoded_cols = encode_value(value.cols);
    if (!encoded_cols) return std::move(encoded_cols).error();
    object.emplace("cols", std::move(encoded_cols).value());
    auto encoded_event_id = encode_value(value.event_id);
    if (!encoded_event_id) return std::move(encoded_event_id).error();
    object.emplace("event_id", std::move(encoded_event_id).value());
    auto encoded_frontend_projection_id = encode_value(value.frontend_projection_id);
    if (!encoded_frontend_projection_id) return std::move(encoded_frontend_projection_id).error();
    object.emplace("frontend_projection_id", std::move(encoded_frontend_projection_id).value());
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    auto encoded_rows = encode_value(value.rows);
    if (!encoded_rows) return std::move(encoded_rows).error();
    object.emplace("rows", std::move(encoded_rows).value());
    return Json(std::move(object));
}

Result<FrontendJournalEventResize> Codec<FrontendJournalEventResize>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    FrontendJournalEventResize result{};
    const Json* field_cell_height = value.find("cell_height");
    if (!field_cell_height) {
        return make_error(ErrorCode::decode, "missing required field 'cell_height'");
    }
    if (field_cell_height) {
        auto decoded = decode_value<std::uint16_t>(*field_cell_height);
        if (!decoded) return std::move(decoded).error();
        result.cell_height = std::move(decoded).value();
    }
    const Json* field_cell_width = value.find("cell_width");
    if (!field_cell_width) {
        return make_error(ErrorCode::decode, "missing required field 'cell_width'");
    }
    if (field_cell_width) {
        auto decoded = decode_value<std::uint16_t>(*field_cell_width);
        if (!decoded) return std::move(decoded).error();
        result.cell_width = std::move(decoded).value();
    }
    const Json* field_cols = value.find("cols");
    if (!field_cols) {
        return make_error(ErrorCode::decode, "missing required field 'cols'");
    }
    if (field_cols) {
        auto decoded = decode_value<std::uint16_t>(*field_cols);
        if (!decoded) return std::move(decoded).error();
        result.cols = std::move(decoded).value();
    }
    const Json* field_event_id = value.find("event_id");
    if (!field_event_id) {
        return make_error(ErrorCode::decode, "missing required field 'event_id'");
    }
    if (field_event_id) {
        auto decoded = decode_value<std::string>(*field_event_id);
        if (!decoded) return std::move(decoded).error();
        result.event_id = std::move(decoded).value();
    }
    const Json* field_frontend_projection_id = value.find("frontend_projection_id");
    if (!field_frontend_projection_id) {
        return make_error(ErrorCode::decode, "missing required field 'frontend_projection_id'");
    }
    if (field_frontend_projection_id) {
        auto decoded = decode_value<std::string>(*field_frontend_projection_id);
        if (!decoded) return std::move(decoded).error();
        result.frontend_projection_id = std::move(decoded).value();
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_rows = value.find("rows");
    if (!field_rows) {
        return make_error(ErrorCode::decode, "missing required field 'rows'");
    }
    if (field_rows) {
        auto decoded = decode_value<std::uint16_t>(*field_rows);
        if (!decoded) return std::move(decoded).error();
        result.rows = std::move(decoded).value();
    }
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        if (*field_kind != Json(std::string("resize"))) {
            return make_error(ErrorCode::decode, "field 'kind' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<FrontendJournalEventViewport>::encode(const FrontendJournalEventViewport& value) {
    (void)value;
    Json::Object object;
    object.emplace("kind", Json(std::string("viewport")));
    auto encoded_event_id = encode_value(value.event_id);
    if (!encoded_event_id) return std::move(encoded_event_id).error();
    object.emplace("event_id", std::move(encoded_event_id).value());
    auto encoded_frontend_projection_id = encode_value(value.frontend_projection_id);
    if (!encoded_frontend_projection_id) return std::move(encoded_frontend_projection_id).error();
    object.emplace("frontend_projection_id", std::move(encoded_frontend_projection_id).value());
    auto encoded_generation = encode_value(value.generation);
    if (!encoded_generation) return std::move(encoded_generation).error();
    object.emplace("generation", std::move(encoded_generation).value());
    auto encoded_offset = encode_value(value.offset);
    if (!encoded_offset) return std::move(encoded_offset).error();
    object.emplace("offset", std::move(encoded_offset).value());
    if (!value.screen_id.is_absent()) {
        auto encoded = encode_value(value.screen_id);
        if (!encoded) return std::move(encoded).error();
        object.emplace("screen_id", std::move(encoded).value());
    }
    auto encoded_settled = encode_value(value.settled);
    if (!encoded_settled) return std::move(encoded_settled).error();
    object.emplace("settled", std::move(encoded_settled).value());
    auto encoded_target = encode_value(value.target);
    if (!encoded_target) return std::move(encoded_target).error();
    object.emplace("target", std::move(encoded_target).value());
    return Json(std::move(object));
}

Result<FrontendJournalEventViewport> Codec<FrontendJournalEventViewport>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    FrontendJournalEventViewport result{};
    const Json* field_event_id = value.find("event_id");
    if (!field_event_id) {
        return make_error(ErrorCode::decode, "missing required field 'event_id'");
    }
    if (field_event_id) {
        auto decoded = decode_value<std::string>(*field_event_id);
        if (!decoded) return std::move(decoded).error();
        result.event_id = std::move(decoded).value();
    }
    const Json* field_frontend_projection_id = value.find("frontend_projection_id");
    if (!field_frontend_projection_id) {
        return make_error(ErrorCode::decode, "missing required field 'frontend_projection_id'");
    }
    if (field_frontend_projection_id) {
        auto decoded = decode_value<std::string>(*field_frontend_projection_id);
        if (!decoded) return std::move(decoded).error();
        result.frontend_projection_id = std::move(decoded).value();
    }
    const Json* field_generation = value.find("generation");
    if (!field_generation) {
        return make_error(ErrorCode::decode, "missing required field 'generation'");
    }
    if (field_generation) {
        auto decoded = decode_value<std::string>(*field_generation);
        if (!decoded) return std::move(decoded).error();
        result.generation = std::move(decoded).value();
    }
    const Json* field_offset = value.find("offset");
    if (!field_offset) {
        return make_error(ErrorCode::decode, "missing required field 'offset'");
    }
    if (field_offset) {
        auto decoded = decode_value<std::uint64_t>(*field_offset);
        if (!decoded) return std::move(decoded).error();
        result.offset = std::move(decoded).value();
    }
    const Json* field_screen_id = value.find("screen_id");
    if (field_screen_id) {
        if (field_screen_id->is_null()) {
            result.screen_id = Field<std::string>::null();
        } else {
            auto decoded = decode_value<std::string>(*field_screen_id);
            if (!decoded) return std::move(decoded).error();
            result.screen_id = Field<std::string>(std::move(decoded).value());
        }
    }
    const Json* field_settled = value.find("settled");
    if (!field_settled) {
        return make_error(ErrorCode::decode, "missing required field 'settled'");
    }
    if (field_settled) {
        auto decoded = decode_value<bool>(*field_settled);
        if (!decoded) return std::move(decoded).error();
        result.settled = std::move(decoded).value();
    }
    const Json* field_target = value.find("target");
    if (!field_target) {
        return make_error(ErrorCode::decode, "missing required field 'target'");
    }
    if (field_target) {
        auto decoded = decode_value<std::uint64_t>(*field_target);
        if (!decoded) return std::move(decoded).error();
        result.target = std::move(decoded).value();
    }
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        if (*field_kind != Json(std::string("viewport"))) {
            return make_error(ErrorCode::decode, "field 'kind' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<IdMappingKind>::encode(const IdMappingKind& value) {
    switch (value) {
        case IdMappingKind::workspace: return Json(std::string("workspace"));
        case IdMappingKind::screen: return Json(std::string("screen"));
        case IdMappingKind::pane: return Json(std::string("pane"));
        case IdMappingKind::surface: return Json(std::string("surface"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<IdMappingKind> Codec<IdMappingKind>::decode(const Json& value) {
    if (value == Json(std::string("workspace"))) return IdMappingKind::workspace;
    if (value == Json(std::string("screen"))) return IdMappingKind::screen;
    if (value == Json(std::string("pane"))) return IdMappingKind::pane;
    if (value == Json(std::string("surface"))) return IdMappingKind::surface;
    return make_error(ErrorCode::decode, "unknown IdMappingKind value");
}

Result<Json> Codec<LayoutLeaf>::encode(const LayoutLeaf& value) {
    (void)value;
    Json::Object object;
    object.emplace("type", Json(std::string("leaf")));
    auto encoded_pane = encode_value(value.pane);
    if (!encoded_pane) return std::move(encoded_pane).error();
    object.emplace("pane", std::move(encoded_pane).value());
    return Json(std::move(object));
}

Result<LayoutLeaf> Codec<LayoutLeaf>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    LayoutLeaf result{};
    const Json* field_pane = value.find("pane");
    if (!field_pane) {
        return make_error(ErrorCode::decode, "missing required field 'pane'");
    }
    if (field_pane) {
        auto decoded = decode_value<Id>(*field_pane);
        if (!decoded) return std::move(decoded).error();
        result.pane = std::move(decoded).value();
    }
    const Json* field_type = value.find("type");
    if (!field_type) {
        return make_error(ErrorCode::decode, "missing required field 'type'");
    }
    if (field_type) {
        if (*field_type != Json(std::string("leaf"))) {
            return make_error(ErrorCode::decode, "field 'type' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<LayoutSplit>::encode(const LayoutSplit& value) {
    (void)value;
    Json::Object object;
    object.emplace("type", Json(std::string("split")));
    auto encoded_a = encode_value(value.a);
    if (!encoded_a) return std::move(encoded_a).error();
    object.emplace("a", std::move(encoded_a).value());
    auto encoded_b = encode_value(value.b);
    if (!encoded_b) return std::move(encoded_b).error();
    object.emplace("b", std::move(encoded_b).value());
    auto encoded_dir = encode_value(value.dir);
    if (!encoded_dir) return std::move(encoded_dir).error();
    object.emplace("dir", std::move(encoded_dir).value());
    auto encoded_ratio = encode_value(value.ratio);
    if (!encoded_ratio) return std::move(encoded_ratio).error();
    object.emplace("ratio", std::move(encoded_ratio).value());
    if (value.split) {
        auto encoded = encode_value(*value.split);
        if (!encoded) return std::move(encoded).error();
        object.emplace("split", std::move(encoded).value());
    }
    return Json(std::move(object));
}

Result<LayoutSplit> Codec<LayoutSplit>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    LayoutSplit result{};
    const Json* field_a = value.find("a");
    if (!field_a) {
        return make_error(ErrorCode::decode, "missing required field 'a'");
    }
    if (field_a) {
        auto decoded = decode_value<std::shared_ptr<Layout>>(*field_a);
        if (!decoded) return std::move(decoded).error();
        result.a = std::move(decoded).value();
    }
    const Json* field_b = value.find("b");
    if (!field_b) {
        return make_error(ErrorCode::decode, "missing required field 'b'");
    }
    if (field_b) {
        auto decoded = decode_value<std::shared_ptr<Layout>>(*field_b);
        if (!decoded) return std::move(decoded).error();
        result.b = std::move(decoded).value();
    }
    const Json* field_dir = value.find("dir");
    if (!field_dir) {
        return make_error(ErrorCode::decode, "missing required field 'dir'");
    }
    if (field_dir) {
        auto decoded = decode_value<SplitDirection>(*field_dir);
        if (!decoded) return std::move(decoded).error();
        result.dir = std::move(decoded).value();
    }
    const Json* field_ratio = value.find("ratio");
    if (!field_ratio) {
        return make_error(ErrorCode::decode, "missing required field 'ratio'");
    }
    if (field_ratio) {
        auto decoded = decode_value<float>(*field_ratio);
        if (!decoded) return std::move(decoded).error();
        result.ratio = std::move(decoded).value();
    }
    const Json* field_split = value.find("split");
    if (field_split) {
        auto decoded = decode_value<Id>(*field_split);
        if (!decoded) return std::move(decoded).error();
        result.split = std::move(decoded).value();
    }
    const Json* field_type = value.find("type");
    if (!field_type) {
        return make_error(ErrorCode::decode, "missing required field 'type'");
    }
    if (field_type) {
        if (*field_type != Json(std::string("split"))) {
            return make_error(ErrorCode::decode, "field 'type' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<LayoutStack>::encode(const LayoutStack& value) {
    (void)value;
    Json::Object object;
    object.emplace("type", Json(std::string("stack")));
    auto encoded_expanded = encode_value(value.expanded);
    if (!encoded_expanded) return std::move(encoded_expanded).error();
    object.emplace("expanded", std::move(encoded_expanded).value());
    auto encoded_panes = encode_value(value.panes);
    if (!encoded_panes) return std::move(encoded_panes).error();
    object.emplace("panes", std::move(encoded_panes).value());
    return Json(std::move(object));
}

Result<LayoutStack> Codec<LayoutStack>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    LayoutStack result{};
    const Json* field_expanded = value.find("expanded");
    if (!field_expanded) {
        return make_error(ErrorCode::decode, "missing required field 'expanded'");
    }
    if (field_expanded) {
        auto decoded = decode_value<Id>(*field_expanded);
        if (!decoded) return std::move(decoded).error();
        result.expanded = std::move(decoded).value();
    }
    const Json* field_panes = value.find("panes");
    if (!field_panes) {
        return make_error(ErrorCode::decode, "missing required field 'panes'");
    }
    if (field_panes) {
        auto decoded = decode_value<std::vector<Id>>(*field_panes);
        if (!decoded) return std::move(decoded).error();
        result.panes = std::move(decoded).value();
    }
    const Json* field_type = value.find("type");
    if (!field_type) {
        return make_error(ErrorCode::decode, "missing required field 'type'");
    }
    if (field_type) {
        if (*field_type != Json(std::string("stack"))) {
            return make_error(ErrorCode::decode, "field 'type' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<TabBrowserSource>::encode(const TabBrowserSource& value) {
    switch (value) {
        case TabBrowserSource::external: return Json(std::string("external"));
        case TabBrowserSource::launched: return Json(std::string("launched"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<TabBrowserSource> Codec<TabBrowserSource>::decode(const Json& value) {
    if (value == Json(std::string("external"))) return TabBrowserSource::external;
    if (value == Json(std::string("launched"))) return TabBrowserSource::launched;
    return make_error(ErrorCode::decode, "unknown TabBrowserSource value");
}

Result<Json> Codec<TabBrowserStatus>::encode(const TabBrowserStatus& value) {
    switch (value) {
        case TabBrowserStatus::starting: return Json(std::string("starting"));
        case TabBrowserStatus::live: return Json(std::string("live"));
        case TabBrowserStatus::failed: return Json(std::string("failed"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<TabBrowserStatus> Codec<TabBrowserStatus>::decode(const Json& value) {
    if (value == Json(std::string("starting"))) return TabBrowserStatus::starting;
    if (value == Json(std::string("live"))) return TabBrowserStatus::live;
    if (value == Json(std::string("failed"))) return TabBrowserStatus::failed;
    return make_error(ErrorCode::decode, "unknown TabBrowserStatus value");
}

Result<Json> Codec<TabKind>::encode(const TabKind& value) {
    switch (value) {
        case TabKind::pty: return Json(std::string("pty"));
        case TabKind::browser: return Json(std::string("browser"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<TabKind> Codec<TabKind>::decode(const Json& value) {
    if (value == Json(std::string("pty"))) return TabKind::pty;
    if (value == Json(std::string("browser"))) return TabKind::browser;
    return make_error(ErrorCode::decode, "unknown TabKind value");
}

Result<Json> Codec<TerminalExitOutcomeExit>::encode(const TerminalExitOutcomeExit& value) {
    (void)value;
    Json::Object object;
    object.emplace("kind", Json(std::string("exit")));
    auto encoded_code = encode_value(value.code);
    if (!encoded_code) return std::move(encoded_code).error();
    object.emplace("code", std::move(encoded_code).value());
    return Json(std::move(object));
}

Result<TerminalExitOutcomeExit> Codec<TerminalExitOutcomeExit>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TerminalExitOutcomeExit result{};
    const Json* field_code = value.find("code");
    if (!field_code) {
        return make_error(ErrorCode::decode, "missing required field 'code'");
    }
    if (field_code) {
        auto decoded = decode_value<std::int32_t>(*field_code);
        if (!decoded) return std::move(decoded).error();
        result.code = std::move(decoded).value();
    }
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        if (*field_kind != Json(std::string("exit"))) {
            return make_error(ErrorCode::decode, "field 'kind' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<TerminalExitOutcomeSignal>::encode(const TerminalExitOutcomeSignal& value) {
    (void)value;
    Json::Object object;
    object.emplace("kind", Json(std::string("signal")));
    auto encoded_core_dumped = encode_value(value.core_dumped);
    if (!encoded_core_dumped) return std::move(encoded_core_dumped).error();
    object.emplace("core_dumped", std::move(encoded_core_dumped).value());
    auto encoded_signal = encode_value(value.signal);
    if (!encoded_signal) return std::move(encoded_signal).error();
    object.emplace("signal", std::move(encoded_signal).value());
    return Json(std::move(object));
}

Result<TerminalExitOutcomeSignal> Codec<TerminalExitOutcomeSignal>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TerminalExitOutcomeSignal result{};
    const Json* field_core_dumped = value.find("core_dumped");
    if (!field_core_dumped) {
        return make_error(ErrorCode::decode, "missing required field 'core_dumped'");
    }
    if (field_core_dumped) {
        auto decoded = decode_value<bool>(*field_core_dumped);
        if (!decoded) return std::move(decoded).error();
        result.core_dumped = std::move(decoded).value();
    }
    const Json* field_signal = value.find("signal");
    if (!field_signal) {
        return make_error(ErrorCode::decode, "missing required field 'signal'");
    }
    if (field_signal) {
        auto decoded = decode_value<std::int32_t>(*field_signal);
        if (!decoded) return std::move(decoded).error();
        result.signal = std::move(decoded).value();
    }
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        if (*field_kind != Json(std::string("signal"))) {
            return make_error(ErrorCode::decode, "field 'kind' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<TerminalExitOutcomeUnknown>::encode(const TerminalExitOutcomeUnknown& value) {
    (void)value;
    Json::Object object;
    object.emplace("kind", Json(std::string("unknown")));
    auto encoded_reason = encode_value(value.reason);
    if (!encoded_reason) return std::move(encoded_reason).error();
    object.emplace("reason", std::move(encoded_reason).value());
    return Json(std::move(object));
}

Result<TerminalExitOutcomeUnknown> Codec<TerminalExitOutcomeUnknown>::decode(const Json& value) {
    auto source = value.as_object();
    if (!source) return std::move(source).error();
    TerminalExitOutcomeUnknown result{};
    const Json* field_reason = value.find("reason");
    if (!field_reason) {
        return make_error(ErrorCode::decode, "missing required field 'reason'");
    }
    if (field_reason) {
        auto decoded = decode_value<std::string>(*field_reason);
        if (!decoded) return std::move(decoded).error();
        result.reason = std::move(decoded).value();
    }
    const Json* field_kind = value.find("kind");
    if (!field_kind) {
        return make_error(ErrorCode::decode, "missing required field 'kind'");
    }
    if (field_kind) {
        if (*field_kind != Json(std::string("unknown"))) {
            return make_error(ErrorCode::decode, "field 'kind' has the wrong literal value");
        }
    }
    return result;
}

Result<Json> Codec<AttachSurfaceRequestMode>::encode(const AttachSurfaceRequestMode& value) {
    switch (value) {
        case AttachSurfaceRequestMode::bytes: return Json(std::string("bytes"));
        case AttachSurfaceRequestMode::render: return Json(std::string("render"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<AttachSurfaceRequestMode> Codec<AttachSurfaceRequestMode>::decode(const Json& value) {
    if (value == Json(std::string("bytes"))) return AttachSurfaceRequestMode::bytes;
    if (value == Json(std::string("render"))) return AttachSurfaceRequestMode::render;
    return make_error(ErrorCode::decode, "unknown AttachSurfaceRequestMode value");
}

Result<Json> Codec<BrowserKeyRequestKind>::encode(const BrowserKeyRequestKind& value) {
    switch (value) {
        case BrowserKeyRequestKind::down: return Json(std::string("down"));
        case BrowserKeyRequestKind::up: return Json(std::string("up"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<BrowserKeyRequestKind> Codec<BrowserKeyRequestKind>::decode(const Json& value) {
    if (value == Json(std::string("down"))) return BrowserKeyRequestKind::down;
    if (value == Json(std::string("up"))) return BrowserKeyRequestKind::up;
    return make_error(ErrorCode::decode, "unknown BrowserKeyRequestKind value");
}

Result<Json> Codec<BrowserMouseRequestKind>::encode(const BrowserMouseRequestKind& value) {
    switch (value) {
        case BrowserMouseRequestKind::down: return Json(std::string("down"));
        case BrowserMouseRequestKind::up: return Json(std::string("up"));
        case BrowserMouseRequestKind::move: return Json(std::string("move"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<BrowserMouseRequestKind> Codec<BrowserMouseRequestKind>::decode(const Json& value) {
    if (value == Json(std::string("down"))) return BrowserMouseRequestKind::down;
    if (value == Json(std::string("up"))) return BrowserMouseRequestKind::up;
    if (value == Json(std::string("move"))) return BrowserMouseRequestKind::move;
    return make_error(ErrorCode::decode, "unknown BrowserMouseRequestKind value");
}

Result<Json> Codec<BrowserMouseGuardedRequestKind>::encode(const BrowserMouseGuardedRequestKind& value) {
    switch (value) {
        case BrowserMouseGuardedRequestKind::down: return Json(std::string("down"));
        case BrowserMouseGuardedRequestKind::up: return Json(std::string("up"));
        case BrowserMouseGuardedRequestKind::move: return Json(std::string("move"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<BrowserMouseGuardedRequestKind> Codec<BrowserMouseGuardedRequestKind>::decode(const Json& value) {
    if (value == Json(std::string("down"))) return BrowserMouseGuardedRequestKind::down;
    if (value == Json(std::string("up"))) return BrowserMouseGuardedRequestKind::up;
    if (value == Json(std::string("move"))) return BrowserMouseGuardedRequestKind::move;
    return make_error(ErrorCode::decode, "unknown BrowserMouseGuardedRequestKind value");
}

Result<Json> Codec<CopyRequestMode>::encode(const CopyRequestMode& value) {
    switch (value) {
        case CopyRequestMode::screen: return Json(std::string("screen"));
        case CopyRequestMode::selection: return Json(std::string("selection"));
        case CopyRequestMode::scrollback: return Json(std::string("scrollback"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<CopyRequestMode> Codec<CopyRequestMode>::decode(const Json& value) {
    if (value == Json(std::string("screen"))) return CopyRequestMode::screen;
    if (value == Json(std::string("selection"))) return CopyRequestMode::selection;
    if (value == Json(std::string("scrollback"))) return CopyRequestMode::scrollback;
    return make_error(ErrorCode::decode, "unknown CopyRequestMode value");
}

Result<Json> Codec<IdsRequestKind>::encode(const IdsRequestKind& value) {
    switch (value) {
        case IdsRequestKind::workspace: return Json(std::string("workspace"));
        case IdsRequestKind::screen: return Json(std::string("screen"));
        case IdsRequestKind::pane: return Json(std::string("pane"));
        case IdsRequestKind::surface: return Json(std::string("surface"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<IdsRequestKind> Codec<IdsRequestKind>::decode(const Json& value) {
    if (value == Json(std::string("workspace"))) return IdsRequestKind::workspace;
    if (value == Json(std::string("screen"))) return IdsRequestKind::screen;
    if (value == Json(std::string("pane"))) return IdsRequestKind::pane;
    if (value == Json(std::string("surface"))) return IdsRequestKind::surface;
    return make_error(ErrorCode::decode, "unknown IdsRequestKind value");
}

Result<Json> Codec<SubscribeRequestTreeEvents>::encode(const SubscribeRequestTreeEvents& value) {
    switch (value) {
        case SubscribeRequestTreeEvents::coarse: return Json(std::string("coarse"));
        case SubscribeRequestTreeEvents::deltas: return Json(std::string("deltas"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<SubscribeRequestTreeEvents> Codec<SubscribeRequestTreeEvents>::decode(const Json& value) {
    if (value == Json(std::string("coarse"))) return SubscribeRequestTreeEvents::coarse;
    if (value == Json(std::string("deltas"))) return SubscribeRequestTreeEvents::deltas;
    return make_error(ErrorCode::decode, "unknown SubscribeRequestTreeEvents value");
}

Result<Json> Codec<ZoomPaneRequestMode>::encode(const ZoomPaneRequestMode& value) {
    switch (value) {
        case ZoomPaneRequestMode::toggle: return Json(std::string("toggle"));
        case ZoomPaneRequestMode::on: return Json(std::string("on"));
        case ZoomPaneRequestMode::off: return Json(std::string("off"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<ZoomPaneRequestMode> Codec<ZoomPaneRequestMode>::decode(const Json& value) {
    if (value == Json(std::string("toggle"))) return ZoomPaneRequestMode::toggle;
    if (value == Json(std::string("on"))) return ZoomPaneRequestMode::on;
    if (value == Json(std::string("off"))) return ZoomPaneRequestMode::off;
    return make_error(ErrorCode::decode, "unknown ZoomPaneRequestMode value");
}

Result<Json> Codec<BrowserStateEventStatus>::encode(const BrowserStateEventStatus& value) {
    switch (value) {
        case BrowserStateEventStatus::starting: return Json(std::string("starting"));
        case BrowserStateEventStatus::live: return Json(std::string("live"));
        case BrowserStateEventStatus::failed: return Json(std::string("failed"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<BrowserStateEventStatus> Codec<BrowserStateEventStatus>::decode(const Json& value) {
    if (value == Json(std::string("starting"))) return BrowserStateEventStatus::starting;
    if (value == Json(std::string("live"))) return BrowserStateEventStatus::live;
    if (value == Json(std::string("failed"))) return BrowserStateEventStatus::failed;
    return make_error(ErrorCode::decode, "unknown BrowserStateEventStatus value");
}

Result<Json> Codec<ClientAttachedEventTransport>::encode(const ClientAttachedEventTransport& value) {
    switch (value) {
        case ClientAttachedEventTransport::unix_: return Json(std::string("unix"));
        case ClientAttachedEventTransport::ws: return Json(std::string("ws"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<ClientAttachedEventTransport> Codec<ClientAttachedEventTransport>::decode(const Json& value) {
    if (value == Json(std::string("unix"))) return ClientAttachedEventTransport::unix_;
    if (value == Json(std::string("ws"))) return ClientAttachedEventTransport::ws;
    return make_error(ErrorCode::decode, "unknown ClientAttachedEventTransport value");
}

Result<Json> Codec<GraphicsStatusEventKind>::encode(const GraphicsStatusEventKind& value) {
    switch (value) {
        case GraphicsStatusEventKind::kitty_image_budget_worker_start_failed: return Json(std::string("kitty-image-budget-worker-start-failed"));
        case GraphicsStatusEventKind::kitty_image_budget_update_failed: return Json(std::string("kitty-image-budget-update-failed"));
        case GraphicsStatusEventKind::cell_pixel_update_retries_exhausted: return Json(std::string("cell-pixel-update-retries-exhausted"));
    }
    return make_error(ErrorCode::invalid_argument, "invalid enum value");
}

Result<GraphicsStatusEventKind> Codec<GraphicsStatusEventKind>::decode(const Json& value) {
    if (value == Json(std::string("kitty-image-budget-worker-start-failed"))) return GraphicsStatusEventKind::kitty_image_budget_worker_start_failed;
    if (value == Json(std::string("kitty-image-budget-update-failed"))) return GraphicsStatusEventKind::kitty_image_budget_update_failed;
    if (value == Json(std::string("cell-pixel-update-retries-exhausted"))) return GraphicsStatusEventKind::cell_pixel_update_retries_exhausted;
    return make_error(ErrorCode::decode, "unknown GraphicsStatusEventKind value");
}

std::string_view Event::name() const noexcept {
    if (const auto* unknown = std::get_if<UnknownEvent>(&value)) {
        return unknown->name;
    }
    const Json* event_name = raw.find("event");
    if (!event_name) return {};
    auto decoded = event_name->as_string();
    return decoded ? decoded.value() : std::string_view{};
}

Result<Json> Codec<Event>::encode(const Event& value) {
    if (const auto* unknown = std::get_if<UnknownEvent>(&value.value)) {
        return unknown->raw;
    }
    return std::visit(
        [](const auto& event) -> Result<Json> {
            using T = std::decay_t<decltype(event)>;
            if constexpr (std::is_same_v<T, UnknownEvent>) return event.raw;
            else return encode_value(event);
        },
        value.value);
}

Result<Event> Codec<Event>::decode(const Json& value) {
    auto name = require_string(value, "event");
    if (!name) return std::move(name).error();
    if (name.value() == "agent-changed") {
        auto decoded = decode_value<AgentChangedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "bell") {
        auto decoded = decode_value<BellEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "browser-state") {
        auto decoded = decode_value<BrowserStateEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "client-attached") {
        auto decoded = decode_value<ClientAttachedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "client-changed") {
        auto decoded = decode_value<ClientChangedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "client-detached") {
        auto decoded = decode_value<ClientDetachedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "client-list-invalidated") {
        auto decoded = decode_value<ClientListInvalidatedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "colors-changed") {
        auto decoded = decode_value<ColorsChangedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "config-reload-requested") {
        auto decoded = decode_value<ConfigReloadRequestedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "detached") {
        auto decoded = decode_value<DetachedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "empty") {
        auto decoded = decode_value<EmptyEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "frame") {
        auto decoded = decode_value<FrameEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "frontend-projection-changed") {
        auto decoded = decode_value<FrontendProjectionChangedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "graphics-status") {
        auto decoded = decode_value<GraphicsStatusEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "layout-changed") {
        auto decoded = decode_value<LayoutChangedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "notification") {
        auto decoded = decode_value<NotificationEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "output") {
        auto decoded = decode_value<OutputEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "overflow") {
        auto decoded = decode_value<OverflowEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "pairing-requested") {
        auto decoded = decode_value<PairingRequestedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "pairing-resolved") {
        auto decoded = decode_value<PairingResolvedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "pane-added") {
        auto decoded = decode_value<PaneAddedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "pane-closed") {
        auto decoded = decode_value<PaneClosedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "render-delta") {
        auto decoded = decode_value<RenderDeltaEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "render-state") {
        auto decoded = decode_value<RenderStateEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "resized") {
        auto decoded = decode_value<ResizedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "screen-added") {
        auto decoded = decode_value<ScreenAddedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "screen-closed") {
        auto decoded = decode_value<ScreenClosedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "screen-renamed") {
        auto decoded = decode_value<ScreenRenamedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "scroll-changed") {
        auto decoded = decode_value<ScrollChangedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "status") {
        auto decoded = decode_value<StatusEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "surface-exited") {
        auto decoded = decode_value<SurfaceExitedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "surface-output") {
        auto decoded = decode_value<SurfaceOutputEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "surface-resize-failed") {
        auto decoded = decode_value<SurfaceResizeFailedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "surface-resized") {
        auto decoded = decode_value<SurfaceResizedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "tab-added") {
        auto decoded = decode_value<TabAddedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "tab-closed") {
        auto decoded = decode_value<TabClosedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "tab-renamed") {
        auto decoded = decode_value<TabRenamedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "terminal-registry-changed") {
        auto decoded = decode_value<TerminalRegistryChangedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "title-changed") {
        auto decoded = decode_value<TitleChangedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "tree-changed") {
        auto decoded = decode_value<TreeChangedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "vt-state") {
        auto decoded = decode_value<VtStateEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "window-title-requested") {
        auto decoded = decode_value<WindowTitleRequestedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "workspace-added") {
        auto decoded = decode_value<WorkspaceAddedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "workspace-closed") {
        auto decoded = decode_value<WorkspaceClosedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "workspace-moved") {
        auto decoded = decode_value<WorkspaceMovedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    if (name.value() == "workspace-renamed") {
        auto decoded = decode_value<WorkspaceRenamedEvent>(value);
        if (!decoded) return std::move(decoded).error();
        return Event{Event::Variant(std::move(decoded).value()), value};
    }
    return Event{
        Event::Variant(UnknownEvent{std::move(name).value(), value}), value};
}

namespace {
constexpr std::array<CommandFieldRequirement, 3> kCommand1FieldRequirements{{
    {"cols", 0U, "attach-initial-size"},
    {"mode", 7U, ""},
    {"rows", 0U, "attach-initial-size"},
}};
constexpr std::array<CommandFieldRequirement, 1> kCommand15FieldRequirements{{
    {"fallback_key", 9U, "clear-history-key-v1"},
}};
constexpr std::array<CommandFieldRequirement, 5> kCommand23FieldRequirements{{
    {"expected_generation", 7U, ""},
    {"expected_revision", 7U, ""},
    {"key", 7U, "workspace-registry-v1"},
    {"mutation_id", 7U, ""},
    {"origin", 7U, ""},
}};
constexpr std::array<CommandFieldRequirement, 1> kCommand25FieldRequirements{{
    {"idempotency_key", 0U, "creation-attempt-keys-v1"},
}};
constexpr std::array<CommandFieldRequirement, 1> kCommand26FieldRequirements{{
    {"terminal_id", 9U, ""},
}};
constexpr std::array<CommandFieldRequirement, 5> kCommand48FieldRequirements{{
    {"expected_generation", 7U, ""},
    {"expected_revision", 7U, ""},
    {"key", 7U, "workspace-registry-v1"},
    {"mutation_id", 7U, ""},
    {"origin", 7U, ""},
}};
constexpr std::array<CommandFieldRequirement, 5> kCommand71FieldRequirements{{
    {"expected_generation", 7U, ""},
    {"expected_revision", 7U, ""},
    {"key", 7U, "workspace-registry-v1"},
    {"mutation_id", 7U, ""},
    {"origin", 7U, ""},
}};
constexpr std::array<CommandFieldRequirement, 1> kCommand77FieldRequirements{{
    {"key", 9U, ""},
}};
constexpr std::array<CommandFieldRequirement, 1> kCommand82FieldRequirements{{
    {"paste", 7U, ""},
}};
constexpr std::array<CommandFieldRequirement, 7> kCommand87FieldRequirements{{
    {"complete", 9U, ""},
    {"cursor", 9U, ""},
    {"cursor_blink", 9U, ""},
    {"cursor_style", 9U, ""},
    {"palette", 9U, ""},
    {"selection_bg", 9U, ""},
    {"selection_fg", 9U, ""},
}};
constexpr std::array<CommandFieldRequirement, 1> kCommand89FieldRequirements{{
    {"transaction", 9U, "layout-undo-v1"},
}};
constexpr std::array<CommandFieldRequirement, 1> kCommand90FieldRequirements{{
    {"transaction", 9U, "layout-undo-v1"},
}};
constexpr std::array<CommandFieldRequirement, 1> kCommand92FieldRequirements{{
    {"force", 10U, "daemon-handoff-force-v1"},
}};
constexpr std::array<CommandFieldRequirement, 2> kCommand95FieldRequirements{{
    {"surface", 9U, "surface-subscribe-filter"},
    {"tree_events", 7U, ""},
}};
constexpr std::array<CommandMetadata, 103> kCommands{{
    {"apply-layout", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"attach-surface", "frontend", 5U, "", true, "attach", "detached", std::span<const CommandFieldRequirement>(kCommand1FieldRequirements)},
    {"browser-activate", "frontend", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"browser-back", "frontend", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"browser-forward", "frontend", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"browser-frame-presented", "frontend", 10U, "browser-pointer-frame-guard-v1", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"browser-insert-text", "frontend", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"browser-key", "frontend", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"browser-key-press", "frontend", 10U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"browser-mouse", "frontend", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"browser-mouse-guarded", "frontend", 10U, "browser-pointer-frame-guard-v1", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"browser-navigate", "frontend", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"browser-reload", "frontend", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"browser-wheel", "frontend", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"browser-wheel-guarded", "frontend", 10U, "browser-pointer-frame-guard-v1", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"clear-history", "control", 9U, "clear-history-v1", false, "", "", std::span<const CommandFieldRequirement>(kCommand15FieldRequirements)},
    {"clear-window-title", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"client-focus", "control", 12U, "client-focus-v1", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"close-pane", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"close-provider-managed-workspace", "provider-authority", 9U, "provider-managed-workspace-authority-v2", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"close-screen", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"close-surface", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"close-terminal", "control", 9U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"close-workspace", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>(kCommand23FieldRequirements)},
    {"copy", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"create-surface-with-receipt", "control", 10U, "creation-receipts-v1", false, "", "", std::span<const CommandFieldRequirement>(kCommand25FieldRequirements)},
    {"create-terminal", "control", 7U, "workspace-registry-v1", false, "", "", std::span<const CommandFieldRequirement>(kCommand26FieldRequirements)},
    {"create-workspace", "control", 7U, "workspace-registry-v1", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"detach-attached-view", "frontend", 10U, "view-attachment-detach-v1", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"detach-client", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"export-layout", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"focus-direction", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"focus-pane", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"get-browser-provider", "local-admin", 10U, "browser-provider-v1", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"get-cell-pixels", "frontend", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"get-frontend-projection", "control", 7U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"identify", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"ids", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"journal-frontend-event", "control", 10U, "frontend-journal-v1", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"list-agents", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"list-clients", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"list-terminals", "control", 9U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"list-workspaces", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"mark-workspaces-provider-managed", "provider-authority", 9U, "provider-managed-workspace-authority-v2", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"mint-terminal-renderer", "frontend", 9U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"mint-terminal-renderer-by-terminal", "frontend", 11U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"move-tab", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"move-terminal", "control", 9U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"move-workspace", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>(kCommand48FieldRequirements)},
    {"new-browser-tab", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"new-pane", "control", 9U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"new-pane-right", "control", 9U, "viewport-splits-v1", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"new-screen", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"new-tab", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"new-workspace", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"notify", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"pairing-response", "local-admin", 7U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"pane-neighbor", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"ping", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"process-info", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"put-frontend-projection", "control", 7U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"read-screen", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"read-scrollback", "control", 7U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"register-browser-provider", "local-admin", 10U, "browser-provider-v1", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"release-attached-view-size", "frontend", 10U, "view-attachment-lease-v1", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"release-surface-size", "control", 7U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"reload-config", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"rename-pane", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"rename-provider-managed-workspace", "provider-authority", 9U, "provider-managed-workspace-authority-v2", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"rename-screen", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"rename-surface", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"rename-workspace", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>(kCommand71FieldRequirements)},
    {"report-agent", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"report-focus", "control", 12U, "client-focus-v1", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"resize-attached-view", "frontend", 10U, "view-attachment-lease-v1", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"resize-surface", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"resolve-terminal", "control", 9U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"run", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>(kCommand77FieldRequirements)},
    {"scroll-surface", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"select-screen", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"select-tab", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"select-workspace", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"send", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>(kCommand82FieldRequirements)},
    {"send-key", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"set-cell-pixels", "frontend", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"set-client-info", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"set-client-sizing", "control", 10U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"set-default-colors", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>(kCommand87FieldRequirements)},
    {"set-ratio", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"set-split-ratio", "control", 8U, "", false, "", "", std::span<const CommandFieldRequirement>(kCommand89FieldRequirements)},
    {"set-viewport-pane-width", "control", 9U, "viewport-column-resize-v1", false, "", "", std::span<const CommandFieldRequirement>(kCommand90FieldRequirements)},
    {"set-window-title", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"shutdown-daemon", "local-admin", 9U, "", false, "", "", std::span<const CommandFieldRequirement>(kCommand92FieldRequirements)},
    {"sidebar-plugin", "frontend", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"split", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"subscribe", "frontend", 5U, "", true, "subscribe", "", std::span<const CommandFieldRequirement>(kCommand95FieldRequirements)},
    {"swap-pane", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"terminal-events", "control", 9U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"undo-layout", "control", 9U, "layout-undo-v1", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"unregister-browser-provider", "local-admin", 10U, "browser-provider-v1", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"vt-state", "control", 5U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"wait-for", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
    {"zoom-pane", "control", 6U, "", false, "", "", std::span<const CommandFieldRequirement>{}},
}};
constexpr std::array<EventMetadata, 46> kEvents{{
    {"agent-changed", 11U, "", "subscribe", "emitted"},
    {"bell", 5U, "", "subscribe", "emitted"},
    {"browser-state", 6U, "", "attach-browser", "emitted"},
    {"client-attached", 6U, "", "subscribe", "emitted"},
    {"client-changed", 6U, "", "subscribe", "emitted"},
    {"client-detached", 6U, "", "subscribe", "emitted"},
    {"client-list-invalidated", 9U, "", "subscribe", "serialized-never-emitted"},
    {"colors-changed", 6U, "", "attach-byte", "emitted"},
    {"config-reload-requested", 6U, "", "subscribe", "emitted"},
    {"detached", 5U, "", "attach-byte,attach-render,attach-browser", "emitted"},
    {"empty", 5U, "", "subscribe", "emitted"},
    {"frame", 6U, "", "attach-browser", "emitted"},
    {"frontend-projection-changed", 7U, "", "subscribe", "emitted"},
    {"graphics-status", 10U, "", "subscribe", "emitted"},
    {"layout-changed", 6U, "", "subscribe", "emitted"},
    {"notification", 6U, "", "subscribe,attach-byte,attach-browser", "emitted"},
    {"output", 5U, "", "attach-byte", "emitted"},
    {"overflow", 7U, "", "subscribe,attach-byte,attach-render,attach-browser", "emitted"},
    {"pairing-requested", 7U, "", "subscribe", "emitted"},
    {"pairing-resolved", 7U, "", "subscribe", "emitted"},
    {"pane-added", 7U, "", "subscribe-deltas", "emitted"},
    {"pane-closed", 7U, "", "subscribe-deltas", "emitted"},
    {"render-delta", 7U, "", "attach-render", "emitted"},
    {"render-state", 7U, "", "attach-render", "emitted"},
    {"resized", 6U, "", "attach-byte", "emitted"},
    {"screen-added", 7U, "", "subscribe-deltas", "emitted"},
    {"screen-closed", 7U, "", "subscribe-deltas", "emitted"},
    {"screen-renamed", 7U, "", "subscribe-deltas", "emitted"},
    {"scroll-changed", 6U, "", "subscribe,attach-byte,attach-render,attach-browser", "emitted"},
    {"status", 5U, "", "subscribe", "emitted"},
    {"surface-exited", 5U, "", "subscribe", "emitted"},
    {"surface-output", 5U, "", "subscribe", "emitted"},
    {"surface-resize-failed", 7U, "", "subscribe", "emitted"},
    {"surface-resized", 5U, "", "subscribe", "emitted"},
    {"tab-added", 7U, "", "subscribe-deltas", "emitted"},
    {"tab-closed", 7U, "", "subscribe-deltas", "emitted"},
    {"tab-renamed", 7U, "", "subscribe-deltas", "emitted"},
    {"terminal-registry-changed", 9U, "", "subscribe", "emitted"},
    {"title-changed", 5U, "", "subscribe", "emitted"},
    {"tree-changed", 5U, "", "subscribe", "emitted"},
    {"vt-state", 5U, "", "attach-byte", "emitted"},
    {"window-title-requested", 6U, "", "subscribe", "emitted"},
    {"workspace-added", 7U, "", "subscribe-deltas", "emitted"},
    {"workspace-closed", 7U, "", "subscribe-deltas", "emitted"},
    {"workspace-moved", 7U, "", "subscribe-deltas", "emitted"},
    {"workspace-renamed", 7U, "", "subscribe-deltas", "emitted"},
}};
}  // namespace

std::span<const CommandMetadata> command_metadata() noexcept { return kCommands; }
std::span<const EventMetadata> event_metadata() noexcept { return kEvents; }

Result<Client> Client::connect(ClientOptions options) {
    auto core = detail::ClientCore::connect(std::move(options));
    if (!core) return std::move(core).error();
    return Client(std::move(core).value());
}

Result<EventStream> Client::open_event_stream(
    std::string_view command, Json::Object parameters,
    std::string terminal_event, RequestOptions options) {
    auto opened = core_.open_stream(
        command, std::move(parameters), std::move(terminal_event), options.timeout);
    if (!opened) return std::move(opened).error();
    return std::move(opened).value().map<Event>(
        [](const Json& event) { return decode_value<Event>(event); });
}

Result<ApplyLayoutResult> Client::apply_layout(
    const ApplyLayoutRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("apply-layout", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ApplyLayoutResult>(response.value());
}

Result<EventStream> Client::attach_surface(
    const AttachSurfaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    return open_event_stream("attach-surface", *parameters.value(), "detached", options);
}

Result<EmptyResult> Client::browser_activate(
    const BrowserActivateRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("browser-activate", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::browser_back(
    const BrowserBackRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("browser-back", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::browser_forward(
    const BrowserForwardRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("browser-forward", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::browser_frame_presented(
    const BrowserFramePresentedRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("browser-frame-presented", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::browser_insert_text(
    const BrowserInsertTextRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("browser-insert-text", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::browser_key(
    const BrowserKeyRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("browser-key", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::browser_key_press(
    const BrowserKeyPressRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("browser-key-press", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::browser_mouse(
    const BrowserMouseRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("browser-mouse", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::browser_mouse_guarded(
    const BrowserMouseGuardedRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("browser-mouse-guarded", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::browser_navigate(
    const BrowserNavigateRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("browser-navigate", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::browser_reload(
    const BrowserReloadRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("browser-reload", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::browser_wheel(
    const BrowserWheelRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("browser-wheel", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::browser_wheel_guarded(
    const BrowserWheelGuardedRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("browser-wheel-guarded", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::clear_history(
    const ClearHistoryRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("clear-history", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::clear_window_title(
    const ClearWindowTitleRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("clear-window-title", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<ClientFocusResult> Client::client_focus(
    const ClientFocusRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("client-focus", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ClientFocusResult>(response.value());
}

Result<EmptyResult> Client::close_pane(
    const ClosePaneRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("close-pane", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<ProviderWorkspaceMutationResult> Client::close_provider_managed_workspace(
    const CloseProviderManagedWorkspaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("close-provider-managed-workspace", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ProviderWorkspaceMutationResult>(response.value());
}

Result<EmptyResult> Client::close_screen(
    const CloseScreenRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("close-screen", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::close_surface(
    const CloseSurfaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("close-surface", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<CloseTerminalResult> Client::close_terminal(
    const CloseTerminalRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("close-terminal", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<CloseTerminalResult>(response.value());
}

Result<WorkspaceMutationResult> Client::close_workspace(
    const CloseWorkspaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("close-workspace", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<WorkspaceMutationResult>(response.value());
}

Result<CopyResult> Client::copy(
    const CopyRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("copy", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<CopyResult>(response.value());
}

Result<JsonValue> Client::create_surface_with_receipt(
    const CreateSurfaceWithReceiptRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("create-surface-with-receipt", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<JsonValue>(response.value());
}

Result<TerminalPlacement> Client::create_terminal(
    const CreateTerminalRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("create-terminal", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<TerminalPlacement>(response.value());
}

Result<WorkspaceMutationResult> Client::create_workspace(
    const CreateWorkspaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("create-workspace", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<WorkspaceMutationResult>(response.value());
}

Result<AttachedViewOutcomeResult> Client::detach_attached_view(
    const DetachAttachedViewRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("detach-attached-view", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<AttachedViewOutcomeResult>(response.value());
}

Result<EmptyResult> Client::detach_client(
    const DetachClientRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("detach-client", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<ExportLayoutResult> Client::export_layout(
    const ExportLayoutRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("export-layout", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ExportLayoutResult>(response.value());
}

Result<FocusDirectionResult> Client::focus_direction(
    const FocusDirectionRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("focus-direction", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<FocusDirectionResult>(response.value());
}

Result<EmptyResult> Client::focus_pane(
    const FocusPaneRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("focus-pane", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<BrowserProviderSnapshot> Client::get_browser_provider(
    const GetBrowserProviderRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("get-browser-provider", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<BrowserProviderSnapshot>(response.value());
}

Result<GetCellPixelsResult> Client::get_cell_pixels(
    const GetCellPixelsRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("get-cell-pixels", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<GetCellPixelsResult>(response.value());
}

Result<FrontendProjection> Client::get_frontend_projection(
    const GetFrontendProjectionRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("get-frontend-projection", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<FrontendProjection>(response.value());
}

Result<IdentifyResult> Client::identify(
    const IdentifyRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("identify", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<IdentifyResult>(response.value());
}

Result<IdsResult> Client::ids(
    const IdsRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("ids", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<IdsResult>(response.value());
}

Result<JournalFrontendEventResult> Client::journal_frontend_event(
    const JournalFrontendEventRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("journal-frontend-event", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<JournalFrontendEventResult>(response.value());
}

Result<ListAgentsResult> Client::list_agents(
    const ListAgentsRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("list-agents", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ListAgentsResult>(response.value());
}

Result<ListClientsResult> Client::list_clients(
    const ListClientsRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("list-clients", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ListClientsResult>(response.value());
}

Result<ListTerminalsResult> Client::list_terminals(
    const ListTerminalsRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("list-terminals", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ListTerminalsResult>(response.value());
}

Result<Tree> Client::list_workspaces(
    const ListWorkspacesRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("list-workspaces", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<Tree>(response.value());
}

Result<EmptyResult> Client::mark_workspaces_provider_managed(
    const MarkWorkspacesProviderManagedRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("mark-workspaces-provider-managed", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<MintTerminalRendererResult> Client::mint_terminal_renderer(
    const MintTerminalRendererRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("mint-terminal-renderer", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<MintTerminalRendererResult>(response.value());
}

Result<MintTerminalRendererResult> Client::mint_terminal_renderer_by_terminal(
    const MintTerminalRendererByTerminalRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("mint-terminal-renderer-by-terminal", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<MintTerminalRendererResult>(response.value());
}

Result<EmptyResult> Client::move_tab(
    const MoveTabRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("move-tab", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<MoveTerminalResult> Client::move_terminal(
    const MoveTerminalRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("move-terminal", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<MoveTerminalResult>(response.value());
}

Result<WorkspaceMutationResult> Client::move_workspace(
    const MoveWorkspaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("move-workspace", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<WorkspaceMutationResult>(response.value());
}

Result<SurfaceResult> Client::new_browser_tab(
    const NewBrowserTabRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("new-browser-tab", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<SurfaceResult>(response.value());
}

Result<SurfaceResult> Client::new_pane(
    const NewPaneRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("new-pane", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<SurfaceResult>(response.value());
}

Result<SurfaceResult> Client::new_pane_right(
    const NewPaneRightRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("new-pane-right", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<SurfaceResult>(response.value());
}

Result<SurfaceResult> Client::new_screen(
    const NewScreenRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("new-screen", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<SurfaceResult>(response.value());
}

Result<SurfaceResult> Client::new_tab(
    const NewTabRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("new-tab", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<SurfaceResult>(response.value());
}

Result<SurfaceResult> Client::new_workspace(
    const NewWorkspaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("new-workspace", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<SurfaceResult>(response.value());
}

Result<NotifyResult> Client::notify(
    const NotifyRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("notify", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<NotifyResult>(response.value());
}

Result<EmptyResult> Client::pairing_response(
    const PairingResponseRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("pairing-response", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<PaneNeighborResult> Client::pane_neighbor(
    const PaneNeighborRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("pane-neighbor", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<PaneNeighborResult>(response.value());
}

Result<PingResult> Client::ping(
    const PingRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("ping", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<PingResult>(response.value());
}

Result<ProcessInfoResult> Client::process_info(
    const ProcessInfoRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("process-info", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ProcessInfoResult>(response.value());
}

Result<FrontendProjection> Client::put_frontend_projection(
    const PutFrontendProjectionRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("put-frontend-projection", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<FrontendProjection>(response.value());
}

Result<ReadScreenResult> Client::read_screen(
    const ReadScreenRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("read-screen", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ReadScreenResult>(response.value());
}

Result<ReadScrollbackResult> Client::read_scrollback(
    const ReadScrollbackRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("read-scrollback", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ReadScrollbackResult>(response.value());
}

Result<BrowserProviderSnapshot> Client::register_browser_provider(
    const RegisterBrowserProviderRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("register-browser-provider", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<BrowserProviderSnapshot>(response.value());
}

Result<AttachedViewOutcomeResult> Client::release_attached_view_size(
    const ReleaseAttachedViewSizeRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("release-attached-view-size", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<AttachedViewOutcomeResult>(response.value());
}

Result<EmptyResult> Client::release_surface_size(
    const ReleaseSurfaceSizeRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("release-surface-size", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<ReloadConfigResult> Client::reload_config(
    const ReloadConfigRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("reload-config", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ReloadConfigResult>(response.value());
}

Result<EmptyResult> Client::rename_pane(
    const RenamePaneRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("rename-pane", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<ProviderWorkspaceMutationResult> Client::rename_provider_managed_workspace(
    const RenameProviderManagedWorkspaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("rename-provider-managed-workspace", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ProviderWorkspaceMutationResult>(response.value());
}

Result<EmptyResult> Client::rename_screen(
    const RenameScreenRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("rename-screen", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::rename_surface(
    const RenameSurfaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("rename-surface", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<WorkspaceMutationResult> Client::rename_workspace(
    const RenameWorkspaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("rename-workspace", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<WorkspaceMutationResult>(response.value());
}

Result<ReportAgentResult> Client::report_agent(
    const ReportAgentRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("report-agent", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ReportAgentResult>(response.value());
}

Result<EmptyResult> Client::report_focus(
    const ReportFocusRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("report-focus", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<AttachedViewResizeResult> Client::resize_attached_view(
    const ResizeAttachedViewRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("resize-attached-view", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<AttachedViewResizeResult>(response.value());
}

Result<ResizeSurfaceResult> Client::resize_surface(
    const ResizeSurfaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("resize-surface", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ResizeSurfaceResult>(response.value());
}

Result<ResolveTerminalResult> Client::resolve_terminal(
    const ResolveTerminalRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("resolve-terminal", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ResolveTerminalResult>(response.value());
}

Result<RunResult> Client::run(
    const RunRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("run", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<RunResult>(response.value());
}

Result<EmptyResult> Client::scroll_surface(
    const ScrollSurfaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("scroll-surface", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::select_screen(
    const SelectScreenRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("select-screen", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::select_tab(
    const SelectTabRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("select-tab", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::select_workspace(
    const SelectWorkspaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("select-workspace", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::send(
    const SendRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("send", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::send_key(
    const SendKeyRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("send-key", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<SetCellPixelsResult> Client::set_cell_pixels(
    const SetCellPixelsRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("set-cell-pixels", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<SetCellPixelsResult>(response.value());
}

Result<EmptyResult> Client::set_client_info(
    const SetClientInfoRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("set-client-info", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::set_client_sizing(
    const SetClientSizingRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("set-client-sizing", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::set_default_colors(
    const SetDefaultColorsRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("set-default-colors", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::set_ratio(
    const SetRatioRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("set-ratio", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::set_split_ratio(
    const SetSplitRatioRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("set-split-ratio", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::set_viewport_pane_width(
    const SetViewportPaneWidthRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("set-viewport-pane-width", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<EmptyResult> Client::set_window_title(
    const SetWindowTitleRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("set-window-title", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<ShutdownDaemonResult> Client::shutdown_daemon(
    const ShutdownDaemonRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("shutdown-daemon", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ShutdownDaemonResult>(response.value());
}

Result<SidebarPluginResult> Client::sidebar_plugin(
    const SidebarPluginRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("sidebar-plugin", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<SidebarPluginResult>(response.value());
}

Result<SurfaceResult> Client::split(
    const SplitRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("split", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<SurfaceResult>(response.value());
}

Result<EventStream> Client::subscribe(
    const SubscribeRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    return open_event_stream("subscribe", *parameters.value(), "", options);
}

Result<EmptyResult> Client::swap_pane(
    const SwapPaneRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("swap-pane", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<EmptyResult>(response.value());
}

Result<TerminalEventsResult> Client::terminal_events(
    const TerminalEventsRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("terminal-events", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<TerminalEventsResult>(response.value());
}

Result<LayoutUndoResult> Client::undo_layout(
    const UndoLayoutRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("undo-layout", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<LayoutUndoResult>(response.value());
}

Result<BrowserProviderUnregisterResult> Client::unregister_browser_provider(
    const UnregisterBrowserProviderRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("unregister-browser-provider", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<BrowserProviderUnregisterResult>(response.value());
}

Result<VtStateResult> Client::vt_state(
    const VtStateRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("vt-state", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<VtStateResult>(response.value());
}

Result<WaitForResult> Client::wait_for(
    const WaitForRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("wait-for", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<WaitForResult>(response.value());
}

Result<ZoomPaneResult> Client::zoom_pane(
    const ZoomPaneRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    auto response = core_.request("zoom-pane", *parameters.value(), options.timeout);
    if (!response) return std::move(response).error();
    return decode_value<ZoomPaneResult>(response.value());
}

Result<DeltaStream> Client::subscribe_deltas(
    const SubscribeRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    (*parameters.value())["tree_events"] = Json("deltas");
    return open_event_stream("subscribe", *parameters.value(), "", options);
}

Result<ByteStream> Client::attach_bytes(
    const AttachSurfaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    parameters.value()->erase("mode");
    return open_event_stream("attach-surface", *parameters.value(), "detached", options);
}

Result<RenderStream> Client::attach_render(
    const AttachSurfaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    (*parameters.value())["mode"] = Json("render");
    return open_event_stream("attach-surface", *parameters.value(), "detached", options);
}

Result<BrowserStream> Client::attach_browser(
    const AttachSurfaceRequest& request, RequestOptions options) {
    auto encoded = encode_value(request);
    if (!encoded) return std::move(encoded).error();
    auto parameters = encoded.value().as_object();
    if (!parameters) return std::move(parameters).error();
    parameters.value()->erase("mode");
    return open_event_stream("attach-surface", *parameters.value(), "detached", options);
}

}  // namespace cmux::raw
