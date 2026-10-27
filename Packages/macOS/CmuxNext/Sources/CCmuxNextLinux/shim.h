// The Linux system interfaces the Glibc module does not import, for the Linux mode of this package
// (linux-tier.json, p15-oracle-126): epoll, eventfd and timerfd, for CmuxNextCompat's PlatformEvents (the
// wait of Chromium's base/message_loop/message_pump_epoll.cc). Darwin builds never see this target.
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
