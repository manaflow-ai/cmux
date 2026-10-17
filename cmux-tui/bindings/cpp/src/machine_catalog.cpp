#include "cmux/resource.hpp"

namespace cmux {
Result<std::vector<MachineSnapshot>> Client::machines() const {
    return detail::ResourceReadResult(read(Operation::machine_list));
}

Result<MachineSnapshot> Machine::refresh() const {
    return read(Operation::machine_get);
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


Result<std::vector<MachineSnapshot>> Client::machines(MachineReadOptions) const {
    return machines();
}
Result<MachineSnapshot> Machine::refresh(MachineReadOptions) const {
    return refresh();
}
}  // namespace cmux
