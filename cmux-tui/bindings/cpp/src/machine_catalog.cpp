#include "cmux/resource.hpp"

namespace cmux {
namespace {
Json::Object catalog_params(MachineReadOptions options) {
    Json::Object params;
    if (options.catalog) params.emplace("catalog", true);
    return params;
}
}  // namespace

Result<std::vector<MachineSnapshot>> Client::machines() const {
    return machines(MachineReadOptions{});
}

Result<MachineSnapshot> Machine::refresh() const {
    return refresh(MachineReadOptions{});
}

Result<std::vector<SessionSnapshot>> Machine::sessions() const {
    return read(Operation::session_list);
}

Session Machine::session(Selector<SessionId> selector) const {
    return Session(state_, std::move(selector), "session", route_);
}

Session Machine::session(SessionId id) const {
    return session(Selector<SessionId>::by_id(std::move(id)));
}

Result<std::vector<MachineSnapshot>> Client::machines(MachineReadOptions options) const {
    return detail::ResourceReadResult(read(Operation::machine_list, catalog_params(options)));
}
Result<MachineSnapshot> Machine::refresh(MachineReadOptions options) const {
    return read(Operation::machine_get, catalog_params(options));
}
}  // namespace cmux
