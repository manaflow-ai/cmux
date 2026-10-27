// The host's fence inbox (host_resize.h): the receive right cmux sends fence
// rights to, checked in under the --resize-fence name before the HELLO.

#include "host_resize.h"

#include <servers/bootstrap.h>

#include <memory>
#include <string>

namespace cmux_host {
namespace {

// The receive buffer: a FenceMessage and the largest trailer.
union FenceBuffer {
  FenceMessage message;
  uint8_t bytes[sizeof(FenceMessage) + sizeof(mach_msg_max_trailer_t)];
};

// cmux's message as FenceMessage sends it: one received send right.
bool WellFormed(const FenceMessage& message) {
  return message.header.msgh_id == kFenceMessageID && message.header.msgh_size == sizeof(FenceMessage) &&
         (message.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0 && message.body.msgh_descriptor_count == 1 &&
         message.fence.type == MACH_MSG_PORT_DESCRIPTOR && message.fence.disposition == MACH_MSG_TYPE_PORT_SEND &&
         message.fence.name != MACH_PORT_NULL && message.seq != 0;
}

class MachFenceInbox final : public FenceInbox {
 public:
  explicit MachFenceInbox(mach_port_t port) : port_(port) {}
  MachFenceInbox(const MachFenceInbox&) = delete;
  MachFenceInbox& operator=(const MachFenceInbox&) = delete;
  ~MachFenceInbox() override {
    for (const Fence& fence : Drain()) Release(fence.right);
    mach_port_mod_refs(mach_task_self(), port_, MACH_PORT_RIGHT_RECEIVE, -1);
  }

  std::vector<Fence> Drain() override {
    std::vector<Fence> fences;
    // The queue holds at most kFenceQueueLimit messages: one more receive finds it empty.
    for (uint32_t taken = 0; taken <= kFenceQueueLimit; ++taken) {
      FenceBuffer buffer = {};
      const kern_return_t result = mach_msg(&buffer.message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
                                            sizeof buffer, port_, 0, MACH_PORT_NULL);
      if (result == MACH_RCV_TOO_LARGE) continue;  // not cmux's: the kernel destroyed it
      if (result != MACH_MSG_SUCCESS) break;       // MACH_RCV_TIMED_OUT: the queue is empty
      if (!WellFormed(buffer.message)) {
        mach_msg_destroy(&buffer.message.header);
        continue;
      }
      fences.push_back({buffer.message.seq, buffer.message.fence.name});
    }
    return fences;
  }

  void Release(uint32_t right) override { mach_port_deallocate(mach_task_self(), right); }

 private:
  mach_port_t port_;
};

}  // namespace

std::unique_ptr<FenceInbox> CheckInFenceInbox(const std::string& name) {
  if (name.empty()) return nullptr;
  const task_t task = mach_task_self();
  mach_port_t port = MACH_PORT_NULL;
  if (bootstrap_check_in(bootstrap_port, name.c_str(), &port) != KERN_SUCCESS) return nullptr;
  mach_port_limits_t limits = {};
  limits.mpl_qlimit = kFenceQueueLimit;
  if (mach_port_set_attributes(task, port, MACH_PORT_LIMITS_INFO, reinterpret_cast<mach_port_info_t>(&limits),
                               MACH_PORT_LIMITS_INFO_COUNT) != KERN_SUCCESS) {
    mach_port_mod_refs(task, port, MACH_PORT_RIGHT_RECEIVE, -1);
    return nullptr;
  }
  return std::make_unique<MachFenceInbox>(port);
}

}  // namespace cmux_host
