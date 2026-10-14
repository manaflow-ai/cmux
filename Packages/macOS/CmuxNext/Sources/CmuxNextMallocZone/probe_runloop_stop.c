// PROBE, NOT FOR MERGE: names who stops the main run loop in the CmuxNext
// Swift Testing helper on the macOS 27 lane (the helper's async main runs
// CFRunLoopRun() and exits 0 when that returns).
//
// A hardware breakpoint on CFRunLoopStop (and _CFRunLoopStopMode) in every
// thread of the test process turns each call into SIGTRAP. The handler logs
// the caller's frames when the target is the main run loop, runs the real
// function with the breakpoint off for that thread, and returns to the
// caller. A run loop observer logs the outermost main run loop's exit.
// Active only in swiftpm-testing-helper and xctest.

#if defined(__arm64__)

#include <dlfcn.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

typedef void (*stop_fn)(void*, void*);
typedef void* (*get_main_fn)(void);

static uint64_t g_targets[2];
static int g_target_count;
static const char* g_target_names[2] = {"CFRunLoopStop", "_CFRunLoopStopMode"};
static void* g_main_loop;
static os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;
static struct sigaction g_old_trap;
static volatile int g_logged;
static volatile int g_calls;
static int g_depth;

static void say(const char* text) {
  write(2, text, strlen(text));
}

static void stamp(char* out, size_t size) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  struct tm tm;
  gmtime_r(&tv.tv_sec, &tm);
  snprintf(out, size, "%02d:%02d:%02d.%06d", tm.tm_hour, tm.tm_min, tm.tm_sec, (int)tv.tv_usec);
}

static void describe(uint64_t address, char* out, size_t size) {
  Dl_info info;
  if (dladdr((void*)address, &info) && info.dli_fname) {
    const char* image = strrchr(info.dli_fname, '/');
    image = image ? image + 1 : info.dli_fname;
    if (info.dli_sname) {
      snprintf(out, size, "%s %s + %llu", image, info.dli_sname,
               (unsigned long long)(address - (uint64_t)info.dli_saddr));
    } else {
      snprintf(out, size, "%s + 0x%llx", image, (unsigned long long)(address - (uint64_t)info.dli_fbase));
    }
  } else {
    snprintf(out, size, "0x%llx", (unsigned long long)address);
  }
}

static arm_debug_state64_t debug_state(int enabled) {
  arm_debug_state64_t state;
  memset(&state, 0, sizeof state);
  if (enabled) {
    for (int i = 0; i < g_target_count; i++) {
      state.__bvr[i] = g_targets[i];
      // Enabled, EL0, all four bytes, address match.
      state.__bcr[i] = (0xFull << 5) | (2ull << 1) | 1ull;
    }
  }
  return state;
}

static kern_return_t set_thread(thread_t thread, int enabled) {
  arm_debug_state64_t state = debug_state(enabled);
  return thread_set_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&state, ARM_DEBUG_STATE64_COUNT);
}

static int arm_all_threads(int report) {
  thread_act_array_t threads;
  mach_msg_type_number_t count = 0;
  if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return -1;
  int failed = 0;
  kern_return_t first_error = KERN_SUCCESS;
  os_unfair_lock_lock(&g_lock);
  for (mach_msg_type_number_t i = 0; i < count; i++) {
    kern_return_t kr = set_thread(threads[i], 1);
    if (kr != KERN_SUCCESS) {
      failed++;
      first_error = kr;
    }
    mach_port_deallocate(mach_task_self(), threads[i]);
  }
  os_unfair_lock_unlock(&g_lock);
  vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
  if (report) {
    char line[200];
    snprintf(line, sizeof line, "\nstop-probe[%d]: armed %u threads, %d failed (kr %d)\n", getpid(), count, failed, first_error);
    say(line);
  }
  return failed;
}

static void* rearm_loop(void* unused) {
  (void)unused;
  for (;;) {
    usleep(200 * 1000);
    arm_all_threads(0);
  }
  return NULL;
}

static void on_trap(int sig, siginfo_t* info, void* context) {
  ucontext_t* uc = (ucontext_t*)context;
  arm_thread_state64_t* ss = &uc->uc_mcontext->__ss;
  uint64_t pc = (uint64_t)__darwin_arm_thread_state64_get_pc(*ss);
  int which = -1;
  for (int i = 0; i < g_target_count; i++) {
    if (pc == g_targets[i]) which = i;
  }
  if (which < 0) {
    // Not ours (a Swift trap): put the old handler back and let the trap run again.
    sigaction(SIGTRAP, &g_old_trap, NULL);
    return;
  }
  uint64_t x0 = ss->__x[0], x1 = ss->__x[1];
  uint64_t lr = (uint64_t)__darwin_arm_thread_state64_get_lr(*ss);
  uint64_t fp = (uint64_t)__darwin_arm_thread_state64_get_fp(*ss);
  __sync_fetch_and_add(&g_calls, 1);

  if ((void*)x0 == g_main_loop && g_logged < 400) {
    __sync_fetch_and_add(&g_logged, 1);
    char line[700], when[32], frame[600];
    stamp(when, sizeof when);
    mach_port_t self = pthread_mach_thread_np(pthread_self());
    char name[64] = "";
    pthread_getname_np(pthread_self(), name, sizeof name);
    snprintf(line, sizeof line, "\nstop-probe[%d]: %s %s(main run loop) on %s thread %u '%s' at depth %d (call %d):\n",
             getpid(), when, g_target_names[which], pthread_main_np() ? "the main" : "a background", self, name,
             g_depth, g_calls);
    say(line);
    describe(lr, frame, sizeof frame);
    snprintf(line, sizeof line, "  0 %s\n", frame);
    say(line);
    uint64_t low = (uint64_t)pthread_get_stackaddr_np(pthread_self()) - pthread_get_stacksize_np(pthread_self());
    uint64_t high = (uint64_t)pthread_get_stackaddr_np(pthread_self());
    for (int n = 1; n < 48 && fp >= low && fp + 16 <= high && (fp & 7) == 0; n++) {
      uint64_t next = ((uint64_t*)fp)[0];
      uint64_t ret = ((uint64_t*)fp)[1] & 0x00007FFFFFFFFFFFull;
      if (!ret) break;
      describe(ret, frame, sizeof frame);
      snprintf(line, sizeof line, "  %d %s\n", n, frame);
      say(line);
      if (next <= fp) break;
      fp = next;
    }
  }

  // Run the real function with this thread's breakpoint off, then return to the caller.
  os_unfair_lock_lock(&g_lock);
  mach_port_t thread = mach_thread_self();
  set_thread(thread, 0);
  ((stop_fn)g_targets[which])((void*)x0, (void*)x1);
  set_thread(thread, 1);
  mach_port_deallocate(mach_task_self(), thread);
  os_unfair_lock_unlock(&g_lock);
  __darwin_arm_thread_state64_set_pc_fptr(*ss, (void*)lr);
  (void)sig;
  (void)info;
}

typedef void* (*observer_create_fn)(void*, uint64_t, unsigned char, long, void (*)(void*, uint64_t, void*), void*);
typedef void (*add_observer_fn)(void*, void*, void*);

static void on_main_loop(void* observer, uint64_t activity, void* info) {
  (void)observer;
  (void)info;
  if (activity == 1) {  // kCFRunLoopEntry
    g_depth++;
    return;
  }
  g_depth--;  // kCFRunLoopExit
  if (g_depth <= 0) {
    char line[200], when[32];
    stamp(when, sizeof when);
    snprintf(line, sizeof line, "\nstop-probe[%d]: %s the outermost main run loop exited (%d CFRunLoopStop calls so far)\n",
             getpid(), when, g_calls);
    say(line);
  }
}

static void at_exit(void) {
  char line[200], when[32];
  stamp(when, sizeof when);
  snprintf(line, sizeof line, "\nstop-probe[%d]: %s exit; %d stop calls, %d on the main run loop logged\n", getpid(), when,
           g_calls, g_logged);
  say(line);
}

__attribute__((constructor)) static void install_stop_probe(void) {
  const char* name = getprogname();
  if (!name || (strcmp(name, "swiftpm-testing-helper") != 0 && strcmp(name, "xctest") != 0)) return;
  for (int i = 0; i < 2; i++) {
    void* symbol = dlsym(RTLD_DEFAULT, g_target_names[i]);
    if (symbol) g_targets[g_target_count++] = (uint64_t)symbol;
  }
  get_main_fn get_main = (get_main_fn)dlsym(RTLD_DEFAULT, "CFRunLoopGetMain");
  if (!g_target_count || !get_main) {
    say("\nstop-probe: no CFRunLoopStop\n");
    return;
  }
  g_main_loop = get_main();

  observer_create_fn create = (observer_create_fn)dlsym(RTLD_DEFAULT, "CFRunLoopObserverCreate");
  add_observer_fn add = (add_observer_fn)dlsym(RTLD_DEFAULT, "CFRunLoopAddObserver");
  void** common = (void**)dlsym(RTLD_DEFAULT, "kCFRunLoopCommonModes");
  if (create && add && common) {
    void* observer = create(NULL, 1 | 128, 1, -2000000, on_main_loop, NULL);  // entry | exit
    if (observer) add(g_main_loop, observer, *common);
  }
  atexit(at_exit);

  struct sigaction action;
  memset(&action, 0, sizeof action);
  action.sa_sigaction = on_trap;
  action.sa_flags = SA_SIGINFO | SA_NODEFER;
  sigaction(SIGTRAP, &action, &g_old_trap);

  arm_debug_state64_t state = debug_state(1);
  kern_return_t task_kr = task_set_state(mach_task_self(), ARM_DEBUG_STATE64, (thread_state_t)&state, ARM_DEBUG_STATE64_COUNT);
  char line[300];
  snprintf(line, sizeof line, "\nstop-probe[%d]: %s; targets", getpid(), name);
  say(line);
  for (int i = 0; i < g_target_count; i++) {
    snprintf(line, sizeof line, " %s=0x%llx", g_target_names[i], (unsigned long long)g_targets[i]);
    say(line);
  }
  snprintf(line, sizeof line, "; main loop %p; task-wide debug state kr %d\n", g_main_loop, task_kr);
  say(line);
  arm_all_threads(1);
  // Self-test: one stop of the main run loop before any run of it (harmless: each run starts unstopped).
  say("\nstop-probe: self-test stop follows\n");
  ((stop_fn)g_targets[0])(g_main_loop, NULL);
  snprintf(line, sizeof line, "\nstop-probe: self-test done; breakpoint %s\n", g_calls > 0 ? "works" : "DID NOT FIRE");
  say(line);
  pthread_t rearm;
  pthread_create(&rearm, NULL, rearm_loop, NULL);
  pthread_detach(rearm);
}

#endif
